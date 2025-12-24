// ===== adaptive_vault.move =====
module protocol::adaptive_vault;

use acl_dex_core::pool::{Self, Pool};
use acl_dex_core::position::{Self, PositionNFT, PositionRegistry};
use nerge_math_lib::full_math;
use nerge_math_lib::liquidity_math;
use nerge_math_lib::tick_math;
use sui::balance::{Self, Balance};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::event;
use sui::table::{Self, Table};

// Error Codes
const E_UNAUTHORIZED: u64 = 1u64;
const E_INSUFFICIENT_SHARES: u64 = 2u64;
const E_NO_SHARES: u64 = 3u64;

/// Vault that holds user deposits and manages positions via RL
public struct AdaptiveVault<phantom Token0, phantom Token1> has key {
    id: UID,
    pool_id: ID,
    // User accounting
    total_shares: u64,
    user_shares: Table<address, u64>,
    // Vault's liquidity positions (RL manages these)
    active_positions: vector<PositionNFT>,
    // RL agent control
    authorized_agent: address,
    // Performance tracking
    total_fees_earned_0: u64,
    total_fees_earned_1: u64,
    rebalance_count: u64,
    // Capital
    reserve_0: Balance<Token0>,
    reserve_1: Balance<Token1>,
}

public struct PositionConfig has copy, drop {
    tick_lower: u32,
    tick_upper: u32,
    capital_allocation_bps: u64, // e.g., 5000 = 50% of capital
}

public struct VaultState has copy, drop {
    total_value_0: u64,
    total_value_1: u64,
    position_count: u64,
    reserve_0: u64,
    reserve_1: u64,
    total_shares: u64,
    fees_earned_0: u64,
    fees_earned_1: u64,
}

/// Event emitted when positions are rebalanced
public struct PositionsRebalanced has copy, drop {
    vault_id: ID,
    new_position_count: u64,
    timestamp: u64,
}

/// User deposits tokens, receives vault shares
public fun deposit<Token0, Token1>(
    vault: &mut AdaptiveVault<Token0, Token1>,
    pool: &mut Pool<Token0, Token1>,
    coin0: Coin<Token0>,
    coin1: Coin<Token1>,
    ctx: &mut TxContext,
): u64 {
    let amount0 = coin::value(&coin0);
    let amount1 = coin::value(&coin1);

    // Calculate shares based on current vault value
    let shares = calculate_shares(vault, pool, amount0, amount1);

    // Add to reserves
    balance::join(&mut vault.reserve_0, coin::into_balance(coin0));
    balance::join(&mut vault.reserve_1, coin::into_balance(coin1));

    // Mint shares
    vault.total_shares = vault.total_shares + shares;

    if (table::contains(&vault.user_shares, tx_context::sender(ctx))) {
        let user_shares = table::borrow_mut(&mut vault.user_shares, tx_context::sender(ctx));
        *user_shares = *user_shares + shares;
    } else {
        table::add(&mut vault.user_shares, tx_context::sender(ctx), shares);
    };

    shares
}

/// RL AGENT ONLY: Rebalance positions
/// This is your key function for adaptive management
public fun rebalance_positions<Token0, Token1>(
    vault: &mut AdaptiveVault<Token0, Token1>,
    pool: &mut Pool<Token0, Token1>,
    registry: &mut PositionRegistry,
    // RL agent's decision
    new_positions: vector<PositionConfig>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Verify RL agent authorization
    assert!(tx_context::sender(ctx) == vault.authorized_agent, E_UNAUTHORIZED);

    // Step 1: Close all existing positions
    close_all_positions(vault, pool, ctx);

    // Step 2: Open new positions based on RL decision
    open_new_positions(vault, pool, registry, new_positions, ctx);

    vault.rebalance_count = vault.rebalance_count + 1;

    event::emit(PositionsRebalanced {
        vault_id: object::id(vault),
        new_position_count: vector::length(&new_positions),
        timestamp: clock::timestamp_ms(clock),
    });
}

/// Helper: Close all active positions
fun close_all_positions<Token0, Token1>(
    vault: &mut AdaptiveVault<Token0, Token1>,
    pool: &mut Pool<Token0, Token1>,
    ctx: &mut TxContext,
) {
    let mut len = vector::length(&vault.active_positions);

    while (len > 0) {
        let mut nft = vector::pop_back(&mut vault.active_positions);
        let liquidity = position::liquidity(&nft);
        let mut principal0 = 0;
        let mut principal1 = 0;

        if (liquidity > 0) {
            // Remove all liquidity
            let (a0, a1) = pool::decrease_liquidity(pool, &mut nft, liquidity, ctx);
            principal0 = a0;
            principal1 = a1;
        };

        // Collect everything (principal + fees)
        let (coin0, coin1) = pool::collect(pool, &mut nft, 0, 0, ctx); // 0,0 means collect all available

        let val0 = coin::value(&coin0);
        let val1 = coin::value(&coin1);

        // Update fee stats
        if (val0 > principal0) {
            vault.total_fees_earned_0 = vault.total_fees_earned_0 + (val0 - principal0);
        };
        if (val1 > principal1) {
            vault.total_fees_earned_1 = vault.total_fees_earned_1 + (val1 - principal1);
        };

        balance::join(&mut vault.reserve_0, coin::into_balance(coin0));
        balance::join(&mut vault.reserve_1, coin::into_balance(coin1));

        // Burn the empty position
        pool::burn_position(pool, nft, ctx);

        len = len - 1;
    };
    // Vector is now empty
}

/// Helper: Open new positions based on RL strategy
fun open_new_positions<Token0, Token1>(
    vault: &mut AdaptiveVault<Token0, Token1>,
    pool: &mut Pool<Token0, Token1>,
    registry: &mut PositionRegistry,
    configs: vector<PositionConfig>,
    ctx: &mut TxContext,
) {
    let mut i = 0;
    let len = vector::length(&configs);

    while (i < len) {
        let config = vector::borrow(&configs, i);

        // Calculate capital allocation for this position
        let amount0 =
            (balance::value(&vault.reserve_0) as u128) * 
                      (config.capital_allocation_bps as u128) / 10000;
        let amount1 =
            (balance::value(&vault.reserve_1) as u128) * 
                      (config.capital_allocation_bps as u128) / 10000;

        // Take from reserves
        let coin0 = coin::take(&mut vault.reserve_0, (amount0 as u64), ctx);
        let coin1 = coin::take(&mut vault.reserve_1, (amount1 as u64), ctx);

        // Mint position
        let (_, _, _, nft) = pool::mint(
            pool,
            registry,
            config.tick_lower,
            config.tick_upper,
            (amount0 as u64),
            (amount1 as u64),
            0,
            0,
            coin0,
            coin1,
            vault.authorized_agent, // Just passed for event emission; NFT comes back to us
            ctx,
        );

        // Store NFT in vault
        vector::push_back(&mut vault.active_positions, nft);

        i = i + 1;
    };
}

/// User withdraws proportional share
public fun withdraw<Token0, Token1>(
    vault: &mut AdaptiveVault<Token0, Token1>,
    pool: &mut Pool<Token0, Token1>,
    shares: u64,
    ctx: &mut TxContext,
): (Coin<Token0>, Coin<Token1>) {
    let user = tx_context::sender(ctx);

    // Verify user has shares
    assert!(table::contains(&vault.user_shares, user), E_NO_SHARES);
    {
        let user_shares = table::borrow_mut(&mut vault.user_shares, user);
        assert!(*user_shares >= shares, E_INSUFFICIENT_SHARES);

        // Update user shares
        *user_shares = *user_shares - shares;
    };

    // Calculate proportional withdrawal
    let total_value_0 = calculate_total_value_0(vault, pool);
    let total_value_1 = calculate_total_value_1(vault, pool);

    let withdraw_0 =
        ((total_value_0 as u128) * (shares as u128) / (vault.total_shares as u128)) as u64;
    let withdraw_1 =
        ((total_value_1 as u128) * (shares as u128) / (vault.total_shares as u128)) as u64;

    // Update total shares
    vault.total_shares = vault.total_shares - shares;

    // Withdraw from reserves (may need to partially close positions)
    let coin0 = coin::take(&mut vault.reserve_0, withdraw_0, ctx);
    let coin1 = coin::take(&mut vault.reserve_1, withdraw_1, ctx);

    (coin0, coin1)
}

/// RL agent can query vault state for decision-making
public fun get_vault_state<Token0, Token1>(
    vault: &AdaptiveVault<Token0, Token1>,
    pool: &Pool<Token0, Token1>,
): VaultState {
    VaultState {
        total_value_0: calculate_total_value_0(vault, pool),
        total_value_1: calculate_total_value_1(vault, pool),
        position_count: vector::length(&vault.active_positions),
        reserve_0: balance::value(&vault.reserve_0),
        reserve_1: balance::value(&vault.reserve_1),
        total_shares: vault.total_shares,
        fees_earned_0: vault.total_fees_earned_0,
        fees_earned_1: vault.total_fees_earned_1,
    }
}

// ========================================================================
// Helper Functions
// ========================================================================

fun calculate_shares<Token0, Token1>(
    vault: &AdaptiveVault<Token0, Token1>,
    pool: &Pool<Token0, Token1>,
    amount0: u64,
    amount1: u64,
): u64 {
    if (vault.total_shares == 0) {
        // Initial share minting - simple sum for initial prototype
        amount0 + amount1
    } else {
        let total0 = calculate_total_value_0(vault, pool);
        let total1 = calculate_total_value_1(vault, pool);

        // Simplified valuation: Sum of amounts.
        // Note: Ideally weighting by oracle/pool price is needed for non-stable pairs.
        let total_val = total0 + total1;
        let deposit_val = amount0 + amount1;

        if (total_val == 0) {
            amount0 + amount1
        } else {
            (
                full_math::mul_div(
                    deposit_val as u256,
                    vault.total_shares as u256,
                    total_val as u256,
                ) as u64,
            )
        }
    }
}

fun calculate_total_value_0<Token0, Token1>(
    vault: &AdaptiveVault<Token0, Token1>,
    pool: &Pool<Token0, Token1>,
): u64 {
    let mut total = balance::value(&vault.reserve_0);
    let (sqrt_price, _, _) = pool::get_slot0(pool);

    let mut i = 0;
    let len = vector::length(&vault.active_positions);
    while (i < len) {
        let nft = vector::borrow(&vault.active_positions, i);
        let token_id = position::token_id(nft);
        // Get position data (liquidity and stored fees)
        let (tick_lower, tick_upper, liquidity, _, _, owed0, _) = pool::get_position_data(
            pool,
            token_id,
        );

        if (liquidity > 0) {
            let sqrt_ratio_a = tick_math::get_sqrt_ratio_at_tick(tick_lower);
            let sqrt_ratio_b = tick_math::get_sqrt_ratio_at_tick(tick_upper);
            let amounts = liquidity_math::get_amounts_for_liquidity(
                sqrt_price,
                sqrt_ratio_a,
                sqrt_ratio_b,
                liquidity,
            );
            total = total + (liquidity_math::get_amount0(&amounts) as u64); // TODO: check this cast
        };
        total = total + owed0;
        i = i + 1;
    };
    total
}

fun calculate_total_value_1<Token0, Token1>(
    vault: &AdaptiveVault<Token0, Token1>,
    pool: &Pool<Token0, Token1>,
): u64 {
    let mut total = balance::value(&vault.reserve_1);
    let (sqrt_price, _, _) = pool::get_slot0(pool);

    let mut i = 0;
    let len = vector::length(&vault.active_positions);
    while (i < len) {
        let nft = vector::borrow(&vault.active_positions, i);
        let token_id = position::token_id(nft);
        let (tick_lower, tick_upper, liquidity, _, _, _, owed1) = pool::get_position_data(
            pool,
            token_id,
        );

        if (liquidity > 0) {
            let sqrt_ratio_a = tick_math::get_sqrt_ratio_at_tick(tick_lower);
            let sqrt_ratio_b = tick_math::get_sqrt_ratio_at_tick(tick_upper);
            let amounts = liquidity_math::get_amounts_for_liquidity(
                sqrt_price,
                sqrt_ratio_a,
                sqrt_ratio_b,
                liquidity,
            );
            total = total + (liquidity_math::get_amount1(&amounts) as u64); // TODO: check this cast
        };
        total = total + owed1;
        i = i + 1;
    };
    total
}
