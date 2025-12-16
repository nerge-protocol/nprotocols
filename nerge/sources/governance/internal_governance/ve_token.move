module protocol::ve_token;

use nerge_math_lib::math;
use sui::balance::{Self, Balance};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::event;
use sui::object::{Self, UID, ID};
use sui::transfer;
use sui::tx_context::{Self, TxContext};

// ==================== Constants ====================

const MAX_LOCK_DURATION_EPOCHS: u64 = 1460; // ~4 years (365 days * 4)
const MIN_LOCK_DURATION_EPOCHS: u64 = 7; // ~1 week
const EPOCHS_PER_YEAR: u64 = 365;

// ==================== Structs ====================

/// veGOV NFT representing locked governance tokens
public struct VeGovPosition<phantom GOV> has key, store {
    id: UID,
    /// Locked governance tokens
    locked_balance: Balance<GOV>,
    /// Lock amount
    amount: u64,
    /// Lock end epoch
    lock_end: u64,
    /// veGOV balance at lock time
    ve_balance: u64,
    /// Lock start epoch
    lock_start: u64,
    /// Original lock duration
    lock_duration: u64,
}

/// Global veGOV state
public struct VeGovState<phantom GOV> has key {
    id: UID,
    /// Total veGOV supply
    total_ve_supply: u64,
    /// Total locked GOV
    total_locked: u64,
    /// Penalty pool for early unlocks
    penalty_pool: Balance<GOV>,
}

// ==================== Events ====================

public struct TokensLocked<phantom GOV> has copy, drop {
    position_id: ID,
    locker: address,
    amount: u64,
    lock_duration: u64,
    ve_balance: u64,
    lock_end: u64,
}

public struct LockExtended<phantom GOV> has copy, drop {
    position_id: ID,
    new_lock_end: u64,
    new_ve_balance: u64,
}

public struct TokensUnlocked<phantom GOV> has copy, drop {
    position_id: ID,
    amount: u64,
    penalty: u64,
}

public struct VeBalanceDecayed<phantom GOV> has copy, drop {
    position_id: ID,
    old_balance: u64,
    new_balance: u64,
}

// ==================== Core Functions ====================

/// Lock GOV tokens to receive veGOV
public fun lock_tokens<GOV>(
    state: &mut VeGovState<GOV>,
    gov_coin: Coin<GOV>,
    lock_duration_epochs: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): VeGovPosition<GOV> {
    assert!(
        lock_duration_epochs >= MIN_LOCK_DURATION_EPOCHS &&
            lock_duration_epochs <= MAX_LOCK_DURATION_EPOCHS,
        E_INVALID_LOCK_DURATION,
    );

    let amount = coin::value(&gov_coin);
    assert!(amount > 0, E_ZERO_AMOUNT);

    let current_epoch = tx_context::epoch(ctx);
    let lock_end = current_epoch + lock_duration_epochs;

    // Calculate veGOV balance: amount * (duration / MAX_DURATION)
    let ve_balance = calculate_ve_balance(amount, lock_duration_epochs);

    // Update global state
    state.total_ve_supply = state.total_ve_supply + ve_balance;
    state.total_locked = state.total_locked + amount;

    let position = VeGovPosition<GOV> {
        id: object::new(ctx),
        locked_balance: coin::into_balance(gov_coin),
        amount,
        lock_end,
        ve_balance,
        lock_start: current_epoch,
        lock_duration: lock_duration_epochs,
    };

    event::emit(TokensLocked<GOV> {
        position_id: object::id(&position),
        locker: tx_context::sender(ctx),
        amount,
        lock_duration: lock_duration_epochs,
        ve_balance,
        lock_end,
    });

    position
}

/// Extend lock duration to increase veGOV balance
public entry fun extend_lock<GOV>(
    state: &mut VeGovState<GOV>,
    position: &mut VeGovPosition<GOV>,
    additional_duration: u64,
    ctx: &TxContext,
) {
    let current_epoch = tx_context::epoch(ctx);
    assert!(position.lock_end > current_epoch, E_LOCK_EXPIRED);

    let remaining_duration = position.lock_end - current_epoch;
    let new_total_duration = remaining_duration + additional_duration;

    assert!(new_total_duration <= MAX_LOCK_DURATION_EPOCHS, E_LOCK_TOO_LONG);

    // Update veGOV balance
    let old_ve_balance = position.ve_balance;
    let new_ve_balance = calculate_ve_balance(position.amount, new_total_duration);

    state.total_ve_supply = state.total_ve_supply - old_ve_balance + new_ve_balance;

    position.lock_end = current_epoch + new_total_duration;
    position.ve_balance = new_ve_balance;
    position.lock_duration = new_total_duration;

    event::emit(LockExtended<GOV> {
        position_id: object::id(position),
        new_lock_end: position.lock_end,
        new_ve_balance,
    });
}

/// Unlock GOV tokens (with penalty if early)
public fun unlock_tokens<GOV>(
    state: &mut VeGovState<GOV>,
    position: VeGovPosition<GOV>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<GOV> {
    // Save position ID before destructuring
    let position_id = object::id(&position);

    let VeGovPosition {
        id,
        mut locked_balance, // Make mutable so we can split penalty
        amount,
        lock_end,
        ve_balance,
        lock_start,
        lock_duration,
    } = position;

    object::delete(id);

    let current_epoch = tx_context::epoch(ctx);

    // Calculate penalty for early unlock
    let (unlock_amount, penalty) = if (current_epoch < lock_end) {
        let remaining = lock_end - current_epoch;
        // Penalty: max(0, (1 - elapsed/total) * 10%)
        let elapsed = current_epoch - lock_start;
        let penalty_bps = if (elapsed < lock_duration) {
            ((lock_duration - elapsed) * 1000) / lock_duration // Up to 10%
        } else {
            0
        };
        let penalty_amount = (amount * penalty_bps) / 10000;
        (amount - penalty_amount, penalty_amount)
    } else {
        // No penalty if lock period complete
        (amount, 0)
    };

    // Update global state
    state.total_ve_supply = if (state.total_ve_supply >= ve_balance) {
        state.total_ve_supply - ve_balance
    } else {
        0
    };
    state.total_locked = state.total_locked - amount;

    // Transfer penalty to penalty pool
    if (penalty > 0) {
        let penalty_balance = balance::split(&mut locked_balance, penalty);
        balance::join(&mut state.penalty_pool, penalty_balance);
    };

    event::emit(TokensUnlocked<GOV> {
        position_id,
        amount: unlock_amount,
        penalty,
    });

    coin::from_balance(locked_balance, ctx)
}

/// Calculate current veGOV balance with decay
public fun get_current_ve_balance<GOV>(position: &VeGovPosition<GOV>, ctx: &TxContext): u64 {
    let current_epoch = tx_context::epoch(ctx);

    if (current_epoch >= position.lock_end) {
        return 0
    };

    let remaining_duration = position.lock_end - current_epoch;
    calculate_ve_balance(position.amount, remaining_duration)
}

// ==================== Helper Functions ====================

/// Calculate veGOV balance: amount * (duration / MAX_DURATION)
fun calculate_ve_balance(amount: u64, duration: u64): u64 {
    ((amount as u128) * (duration as u128) / (MAX_LOCK_DURATION_EPOCHS as u128)) as u64
}

// ==================== View Functions ====================

/// Get position details
public fun get_position_info<GOV>(position: &VeGovPosition<GOV>): (u64, u64, u64, u64) {
    (position.amount, position.ve_balance, position.lock_end, position.lock_duration)
}

/// Get total veGOV supply
public fun get_total_ve_supply<GOV>(state: &VeGovState<GOV>): u64 {
    state.total_ve_supply
}

/// Get total locked GOV
public fun get_total_locked<GOV>(state: &VeGovState<GOV>): u64 {
    state.total_locked
}

// ==================== Error Codes ====================

const E_INVALID_LOCK_DURATION: u64 = 500;
const E_ZERO_AMOUNT: u64 = 501;
const E_LOCK_EXPIRED: u64 = 502;
const E_LOCK_TOO_LONG: u64 = 503;
const E_LOCK_NOT_EXPIRED: u64 = 504;
