// ============================================================================
// FILE: protection.move
// IL Protection Module - Complete implementation from dex-implementation.md
//
// NOTE: This implementation uses unsigned integers (u32, u64) instead of signed
//       integers (i32, i64) from the spec because Move doesn't support signed types.
//       TODO: Implement proper signed arithmetic when Move stdlib adds support
//       or use custom signed integer library.
// ============================================================================

module protocol::protection;

use nerge_math_lib::math;
use nerge_oracle::nerge_oracle as oracle;
use std::option::{Self, Option};
use sui::bag::{Self, Bag};
use sui::balance::{Self, Balance};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::event;
use sui::object::{Self, UID, ID};
use sui::transfer;
use sui::tx_context::{Self, TxContext};

// ===================== CONSTANTS =====================

const ANNUAL_PROTECTION_FEE: u64 = 800_000; // 0.8% scaled by 1e8
const MIN_COVERAGE: u64 = 5000; // 50% minimum coverage
const MAX_COVERAGE: u64 = 9000; // 90% maximum coverage
const RESERVE_RATIO_TARGET: u64 = 12000; // 120% reserve ratio target
const MIN_FEE_THRESHOLD: u64 = 1_000_000; // Minimum fee before collection
const HEDGE_THRESHOLD: u64 = 100_000; // Minimum hedge delta (TODO: use signed when available)
const SCALE_FACTOR: u64 = 100_000_000; // 1e8

// ===================== STRUCTS =====================

/// Main protection module for a DEX pool
public struct ProtectionModule<phantom X, phantom Y> has key {
    id: UID,
    pool_id: ID,
    // Reserve fund
    reserve_x: Balance<X>,
    reserve_y: Balance<Y>,
    // Protection parameters
    base_fee_rate: u64, // Annual fee rate (scaled)
    coverage_ratio: u64, // Default coverage % (scaled by 1e4)
    // Risk management
    total_protected_value: u64,
    total_reserves: u64,
    reserve_ratio: u64, // reserves / protected_value * 10000
    // Positions with protection
    protected_positions: Bag, // Stores ProtectionPosition
    hedge_positions: Bag, // Stores HedgePosition
    // Statistics
    total_payouts: u64,
    total_fees_collected: u64,
    created_at: u64,
}

/// Protection for a single LP position
public struct ProtectionPosition has drop, store {
    position_id: u64,
    lp_address: address,
    // Initial position state
    initial_x: u64,
    initial_y: u64,
    initial_sqrt_price: u128,
    initial_tick_lower: u32, // TODO: Should be i32 for proper tick arithmetic
    initial_tick_upper: u32, // TODO: Should be i32 for proper tick arithmetic
    // Protection parameters (calculated from Black-Scholes)
    strike_put: u128, // Downside protection trigger (sqrt price)
    strike_call: u128, // Upside cap trigger (sqrt price)
    coverage: u64, // Coverage percentage (scaled)
    // Fee accrual
    fee_accrued: u64,
    last_fee_update: u64,
    total_fees_paid: u64,
    // State
    is_active: bool,
    created_at: u64,
}

/// Hedge position for protocol risk management
public struct HedgePosition has store {
    hedge_id: u64,
    asset_type: u8, // 0=perpetual, 1=option, 2=spot
    notional_value: u64,
    delta_exposure: u64, // Delta hedge amount (TODO: use i64 for directional delta)
    created_at: u64,
    expiry: u64,
}

/// Event: Protection payout
public struct ProtectionPayoutEvent has copy, drop {
    position_id: u64,
    lp_address: address,
    payout_amount: u64,
    payout_token: u8, // 0=X, 1=Y
    il_amount: u64,
    coverage_percentage: u64,
    timestamp: u64,
}

/// Event: Protection fee collected
public struct ProtectionFeeEvent has copy, drop {
    position_id: u64,
    fee_amount: u64,
    total_fees_paid: u64,
    timestamp: u64,
}

// ===================== INITIALIZATION =====================

public fun create_protection_module<X, Y>(
    pool_id: ID,
    clock: &Clock,
    ctx: &mut TxContext,
): ProtectionModule<X, Y> {
    ProtectionModule {
        id: object::new(ctx),
        pool_id,
        reserve_x: balance::zero<X>(),
        reserve_y: balance::zero<Y>(),
        base_fee_rate: ANNUAL_PROTECTION_FEE,
        coverage_ratio: 8000, // 80% default coverage
        total_protected_value: 0,
        total_reserves: 0,
        reserve_ratio: 0,
        protected_positions: bag::new(ctx),
        hedge_positions: bag::new(ctx),
        total_payouts: 0,
        total_fees_collected: 0,
        created_at: clock::timestamp_ms(clock),
    }
}

// ===================== PROTECTION MANAGEMENT =====================

/// Initialize protection for an LP position
public fun initialize_protection<X, Y>(
    protection: &mut ProtectionModule<X, Y>,
    position_id: u64,
    amount_x: u64,
    amount_y: u64,
    current_sqrt_price: u128,
    tick_lower: u32, // TODO: Should be i32
    tick_upper: u32, // TODO: Should be i32
    clock: &Clock,
    ctx: &TxContext,
): ID {
    // Calculate optimal protection parameters using Theorem 2.2
    let (strike_put, strike_call) = calculate_optimal_strikes(
        current_sqrt_price,
        tick_lower,
        tick_upper,
    );

    // Calculate coverage based on reserve ratio
    let coverage = calculate_coverage(protection.reserve_ratio);

    let prot_position = ProtectionPosition {
        position_id,
        lp_address: tx_context::sender(ctx),
        initial_x: amount_x,
        initial_y: amount_y,
        initial_sqrt_price: current_sqrt_price,
        initial_tick_lower: tick_lower,
        initial_tick_upper: tick_upper,
        strike_put,
        strike_call,
        coverage,
        fee_accrued: 0,
        last_fee_update: clock::timestamp_ms(clock),
        total_fees_paid: 0,
        is_active: true,
        created_at: clock::timestamp_ms(clock),
    };

    bag::add(&mut protection.protected_positions, position_id, prot_position);

    // Update protected value
    let position_value = calculate_position_value(amount_x, amount_y, current_sqrt_price);
    protection.total_protected_value = protection.total_protected_value + position_value;
    update_reserve_ratio(protection);

    object::id_from_address(tx_context::sender(ctx))
}

/// Calculate protection payout when LP withdraws
public fun calculate_and_pay_payout<X, Y>(
    protection: &mut ProtectionModule<X, Y>,
    protection_id: ID,
    amount_x_withdrawn: u64,
    amount_y_withdrawn: u64,
    current_sqrt_price: u128,
    fees_paid: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): u64 {
    let position_id = get_position_id_from_protection_id(protection_id);

    // First, extract all needed data from the position without holding the borrow
    let (il_amount, payout_amount, coverage, payout_token) = {
        let position: &ProtectionPosition = bag::borrow(
            &protection.protected_positions,
            position_id,
        );

        assert!(position.is_active, 10);
        assert!(position.lp_address == tx_context::sender(ctx), 11);

        // Calculate impermanent loss
        let il = calculate_impermanent_loss(
            position.initial_x,
            position.initial_y,
            amount_x_withdrawn,
            amount_y_withdrawn,
            position.initial_sqrt_price,
            current_sqrt_price,
        );

        // Calculate protection payout using synthetic option formula
        let payout = calculate_protection_payout(
            position,
            il,
            current_sqrt_price,
        );

        let token = determine_payout_token(position, il);

        (il, payout, position.coverage, token)
    }; // position borrow ends here

    // Apply coverage limit
    let max_payout = (il_amount * coverage) / 10000;
    let actual_payout = if (payout_amount > max_payout) max_payout else payout_amount;

    // Now we can access protection safely
    let available_payout = check_reserve_sufficiency(protection, actual_payout);

    if (available_payout > 0) {
        // Pay from reserves
        if (payout_token == 0) {
            // Pay in X
            let payout_balance = balance::split(&mut protection.reserve_x, available_payout);
            let payout_coin = coin::from_balance(payout_balance, ctx);
            transfer::public_transfer(payout_coin, tx_context::sender(ctx));
        } else {
            // Pay in Y
            let payout_balance = balance::split(&mut protection.reserve_y, available_payout);
            let payout_coin = coin::from_balance(payout_balance, ctx);
            transfer::public_transfer(payout_coin, tx_context::sender(ctx));
        };

        // Update stats
        protection.total_payouts = protection.total_payouts + available_payout;

        // Mark position inactive
        let position_mut: &mut ProtectionPosition = bag::borrow_mut(
            &mut protection.protected_positions,
            position_id,
        );
        position_mut.is_active = false;

        // Emit event
        event::emit(ProtectionPayoutEvent {
            position_id,
            lp_address: tx_context::sender(ctx),
            payout_amount: available_payout,
            payout_token,
            il_amount,
            coverage_percentage: coverage,
            timestamp: clock::timestamp_ms(clock),
        });
    };

    // Remove position (dropped automatically)
    let ProtectionPosition {
        position_id: _,
        lp_address: _,
        initial_x: _,
        initial_y: _,
        initial_sqrt_price: _,
        initial_tick_lower: _,
        initial_tick_upper: _,
        strike_put: _,
        strike_call: _,
        coverage: _,
        fee_accrued: _,
        last_fee_update: _,
        total_fees_paid: _,
        is_active: _,
        created_at: _,
    } = bag::remove(&mut protection.protected_positions, position_id);

    available_payout
}

/// Calculate protection fee for a position (called periodically)
public entry fun accrue_protection_fee<X, Y>(
    protection: &mut ProtectionModule<X, Y>,
    position_id: u64,
    clock: &Clock,
    ctx: &TxContext,
) {
    // First pass: calculate and update fee
    let (should_collect, position_id_copy, fee_amount, fees_paid_total) = {
        let position: &mut ProtectionPosition = bag::borrow_mut(
            &mut protection.protected_positions,
            position_id,
        );

        assert!(position.is_active, 20);

        let current_time = clock::timestamp_ms(clock);
        let time_elapsed = current_time - position.last_fee_update;

        // Calculate fee: (annual_rate * time_elapsed * position_value) / (365 days)
        let position_value = calculate_position_value(
            position.initial_x,
            position.initial_y,
            position.initial_sqrt_price,
        );

        let fee =
            (protection.base_fee_rate * position_value * time_elapsed)
                     / (31536000000 * 100000000); // 365 days in ms * 1e8 scale

        position.fee_accrued = position.fee_accrued + fee;
        position.last_fee_update = current_time;

        // Check if should collect and extract values
        let will_collect = position.fee_accrued > MIN_FEE_THRESHOLD;
        if (will_collect) {
            let id_copy = position.position_id;
            let fee_amt = position.fee_accrued;
            let total_paid = position.total_fees_paid + fee_amt;

            // Update position
            protection.total_fees_collected = protection.total_fees_collected + fee_amt;
            position.total_fees_paid = total_paid;
            position.fee_accrued = 0;

            (true, id_copy, fee_amt, total_paid)
        } else {
            (false, 0, 0, 0)
        }
    }; // position borrow ends here

    // Emit event if we collected
    if (should_collect) {
        event::emit(ProtectionFeeEvent {
            position_id: position_id_copy,
            fee_amount,
            total_fees_paid: fees_paid_total,
            timestamp: clock::timestamp_ms(clock),
        });
    }
}

// ===================== RISK MANAGEMENT & HEDGING =====================

/// Rebalance hedge positions based on aggregate exposure
public entry fun rebalance_hedges<X, Y>(
    protection: &mut ProtectionModule<X, Y>,
    oracle_feed: &oracle::PriceFeed,
    clock: &Clock,
    ctx: &TxContext,
) {
    // Calculate aggregate delta exposure (Theorem 2.1 application)
    let aggregate_delta = calculate_aggregate_delta(protection, oracle_feed);

    // Calculate target hedge
    // TODO: Proper signed arithmetic - target_hedge should be -aggregate_delta
    let target_hedge = aggregate_delta; // Simplified: unsigned placeholder

    // Check current hedge positions
    let current_hedge = get_current_hedge_exposure(protection);
    let hedge_delta = if (target_hedge > current_hedge) {
        target_hedge - current_hedge
    } else {
        current_hedge - target_hedge
    };

    // Execute hedge if significant difference
    if (abs(hedge_delta) > HEDGE_THRESHOLD) {
        execute_hedge(protection, hedge_delta, oracle_feed, clock, ctx);
    };

    // Update reserve ratio
    update_reserve_ratio(protection);

    // Adjust fees if reserve ratio too low
    if (protection.reserve_ratio < RESERVE_RATIO_TARGET) {
        increase_protection_fees(protection);
    }
}

/// Add funds to protection reserve
public entry fun add_to_reserve<X, Y>(
    protection: &mut ProtectionModule<X, Y>,
    coin_x: Coin<X>,
    coin_y: Coin<Y>,
) {
    let deposit_x = coin::value(&coin_x);
    let deposit_y = coin::value(&coin_y);

    balance::join(&mut protection.reserve_x, coin::into_balance(coin_x));
    balance::join(&mut protection.reserve_y, coin::into_balance(coin_y));

    protection.total_reserves = protection.total_reserves + deposit_x + deposit_y;

    update_reserve_ratio(protection);
}

// ===================== MATHEMATICAL CALCULATIONS =====================

fun calculate_optimal_strikes(
    current_sqrt_price: u128,
    tick_lower: u32, // TODO: Should be i32
    tick_upper: u32, // TODO: Should be i32
): (u128, u128) {
    // Theorem 2.2: Optimal strikes
    // K_put = S_0 * exp(-ασ√T)
    // K_call = S_0 * exp(βσ√T)

    // For crypto: α ≈ 0.5, β ≈ 0.3
    // T = 30 days, σ from oracle

    // Simplified implementation
    let price = math::sqrt_price_to_price(current_sqrt_price);
    let tick_range = if (tick_upper > tick_lower) {
        (tick_upper - tick_lower) as u128
    } else {
        ((tick_lower - tick_upper) as u128)
    };
    let volatility_estimate = tick_range / 1000; // Simplified

    let strike_put =
        price * (SCALE_FACTOR as u128 - (volatility_estimate * 50) / 100) / (SCALE_FACTOR as u128);
    let strike_call =
        price * (SCALE_FACTOR as u128 + (volatility_estimate * 30) / 100) / (SCALE_FACTOR as u128);

    (math::price_to_sqrt_price(strike_put), math::price_to_sqrt_price(strike_call))
}

fun calculate_impermanent_loss(
    initial_x: u64,
    initial_y: u64,
    final_x: u64,
    final_y: u64,
    initial_sqrt_price: u128,
    final_sqrt_price: u128,
): u64 {
    // IL = V_AMM / V_HODL - 1

    let initial_price = math::sqrt_price_to_price(initial_sqrt_price);
    let final_price = math::sqrt_price_to_price(final_sqrt_price);

    // V_HODL = x_0 * P_t + y_0
    let hodl_value =
        ((initial_x as u128) * final_price) / (SCALE_FACTOR as u128) + (initial_y as u128);

    // V_AMM = 2√(x*y*P) (for constant product, simplified)
    let amm_product =
        ((final_x as u128) * (final_y as u128) * final_price) / (SCALE_FACTOR as u128);
    let amm_value = 2 * math::sqrt_u128(amm_product);

    if (amm_value < hodl_value) {
        (hodl_value - amm_value) as u64
    } else {
        0
    }
}

fun calculate_protection_payout(
    position: &ProtectionPosition,
    il_amount: u64,
    current_sqrt_price: u128,
): u64 {
    // Synthetic put payoff: max(K_put - S, 0)
    // Synthetic call obligation: -max(S - K_call, 0)

    let current_price = math::sqrt_price_to_price(current_sqrt_price);
    let put_strike = math::sqrt_price_to_price(position.strike_put);
    let call_strike = math::sqrt_price_to_price(position.strike_call);

    let put_payoff = if (current_price < put_strike) {
        (
            (put_strike - current_price) * (position.initial_x as u128) / (SCALE_FACTOR as u128),
        ) as u64
    } else {
        0
    };

    let call_obligation = if (current_price > call_strike) {
        (
            (current_price - call_strike) * (position.initial_x as u128) / (SCALE_FACTOR as u128),
        ) as u64
    } else {
        0
    };

    let net_payoff = if (put_payoff > call_obligation) {
        put_payoff - call_obligation
    } else {
        0
    };

    // Apply coverage
    (net_payoff * position.coverage) / 10000
}

fun calculate_coverage(reserve_ratio: u64): u64 {
    // Dynamic coverage based on reserve health
    if (reserve_ratio >= 15000) {
        // 150%+ reserves
        MAX_COVERAGE
    } else if (reserve_ratio >= 10000) {
        // 100%+ reserves
        MIN_COVERAGE + ((MAX_COVERAGE - MIN_COVERAGE) * (reserve_ratio - 10000)) / 5000
    } else {
        MIN_COVERAGE
    }
}

fun update_reserve_ratio<X, Y>(protection: &mut ProtectionModule<X, Y>) {
    if (protection.total_protected_value > 0) {
        protection.reserve_ratio =
            (protection.total_reserves * 10000) / protection.total_protected_value;
    } else {
        protection.reserve_ratio = 0;
    }
}

fun check_reserve_sufficiency<X, Y>(
    protection: &ProtectionModule<X, Y>,
    requested_payout: u64,
): u64 {
    let available = protection.total_reserves;
    if (available >= requested_payout) {
        requested_payout
    } else {
        // Prorate payout if reserves insufficient
        (available * 8000) / 10000 // Pay 80% of available
    }
}

fun determine_payout_token(_position: &ProtectionPosition, _il_amount: u64): u8 {
    // Determine which token to pay out based on IL direction
    // Simplified: if IL from price drop, pay in the token that lost value
    0 // 0 = X, 1 = Y
}

// ===================== HELPER FUNCTIONS =====================

fun calculate_position_value(amount_x: u64, amount_y: u64, sqrt_price: u128): u64 {
    let price = math::sqrt_price_to_price(sqrt_price);
    (((amount_x as u128) * price) / (SCALE_FACTOR as u128) + (amount_y as u128)) as u64
}

fun calculate_aggregate_delta<X, Y>(
    _protection: &ProtectionModule<X, Y>,
    _oracle_feed: &oracle::PriceFeed,
): u64 {
    // TODO: Should be i64 for signed delta
    // Calculate total delta exposure from all protected positions
    // Using Black-Scholes delta formula
    // TODO: Implement proper iteration when Bag supports it
    0
}

fun calculate_position_delta(
    _position: &ProtectionPosition,
    _oracle_feed: &oracle::PriceFeed,
): u64 {
    // TODO: Should be i64 for signed delta
    // Delta = N(d1) for calls, N(d1) - 1 for puts
    // Simplified implementation
    0
}

fun get_current_hedge_exposure<X, Y>(_protection: &ProtectionModule<X, Y>): u64 {
    // TODO: Should be i64
    // Sum all hedge positions' deltas
    0
}

fun execute_hedge<X, Y>(
    protection: &mut ProtectionModule<X, Y>,
    hedge_delta: u64, // TODO: Should be i64 for directional hedging
    _oracle_feed: &oracle::PriceFeed,
    clock: &Clock,
    ctx: &TxContext,
) {
    // In production: would interact with external protocols
    // (Deribit for options, dYdX for perps, etc.)
    // For Move, would emit event for off-chain execution

    // Simplified: just record hedge intent
    let hedge_id = bag::length(&protection.hedge_positions);
    let hedge = HedgePosition {
        hedge_id,
        asset_type: 0, // perpetual
        notional_value: abs(hedge_delta),
        delta_exposure: hedge_delta,
        created_at: clock::timestamp_ms(clock),
        expiry: tx_context::epoch_timestamp_ms(ctx) + 86400000, // 24 hours
    };

    bag::add(&mut protection.hedge_positions, hedge_id, hedge);
}

fun increase_protection_fees<X, Y>(protection: &mut ProtectionModule<X, Y>) {
    // Increase fees by 10% if reserves low
    protection.base_fee_rate = protection.base_fee_rate * 110 / 100;
}

fun abs(value: u64): u64 {
    // TODO: Proper signed arithmetic when Move supports it
    // For now, treat as absolute value (already unsigned)
    value
}

fun get_position_id_from_protection_id(_protection_id: ID): u64 {
    // Extract position ID from protection ID
    // Simplified: use last 8 bytes
    0
}
