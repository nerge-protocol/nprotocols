// ===== adaptive_vault.move =====
// Vault for RL-driven Adaptive Concentrated Liquidity Management
module protocol::adaptive_vaul;

use acl_dex_core::pool::{Self, Pool};
use acl_dex_core::position::{Self, PositionNFT, PositionRegistry};
use nerge_math_lib::liquidity_math;
use nerge_math_lib::tick_math;
use std::vector;
use sui::balance::{Self, Balance};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::event;
use sui::object::{Self, UID, ID};
use sui::table::{Self, Table};
use sui::transfer;
use sui::tx_context::{Self, TxContext};

// ===== Constants =====
const SHARES_PRECISION: u128 = 1_000_000_000; // 9 decimals for share calculations
const MAX_POSITIONS: u64 = 10;
const MIN_DEPOSIT: u64 = 1_000_000; // Prevent dust deposits

// ===== Error Codes =====
const E_UNAUTHORIZED: u64 = 1;
const E_INSUFFICIENT_SHARES: u64 = 2;
const E_NO_SHARES: u64 = 3;
const E_TOO_MANY_POSITIONS: u64 = 4;
const E_INVALID_ALLOCATION: u64 = 5;
const E_VAULT_PAUSED: u64 = 6;
const E_MIN_DEPOSIT: u64 = 7;
const E_ZERO_LIQUIDITY: u64 = 8;
const E_REBALANCE_TOO_SOON: u64 = 9;
const E_INVALID_POSITION_CONFIG: u64 = 10;

// ===== Core Structs =====

/// Admin capability for vault management
public struct VaultAdminCap has key, store {
    id: UID,
    vault_id: ID,
}

/// The main adaptive vault
public struct AdaptiveVault<phantom Token0, phantom Token1> has key {
    id: UID,
    // Pool reference
    pool_id: ID,
    // User shares accounting
    total_shares: u128,
    user_shares: Table<address, u128>,
    // Active positions (NFTs owned by vault)
    active_positions: vector<u64>, // Store token_ids
    position_nfts: Table<u64, PositionNFT>, // Store actual NFTs
    // RL Agent control
    authorized_agent: address,
    agent_performance_score: u64, // Out of 10000
    // Performance tracking
    total_fees_earned_0: u64,
    total_fees_earned_1: u64,
    total_rebalances: u64,
    last_rebalance_time: u64,
    // Capital reserves (idle capital not in positions)
    reserve_0: Balance<Token0>,
    reserve_1: Balance<Token1>,
    // Safety controls
    paused: bool,
    min_rebalance_interval_ms: u64,
    // Constraints for RL agent
    constraints: AgentConstraints,
}

/// Constraints that RL agent must respect
public struct AgentConstraints has copy, drop, store {
    max_positions: u64,
    min_positions: u64,
    max_single_position_bps: u64, // Max % in one position
    max_range_width_ticks: u32,
    min_range_width_ticks: u32,
    max_distance_from_current_tick: u32,
}

/// Configuration for a single position
public struct PositionConfig has copy, drop, store {
    tick_lower: u32,
    tick_upper: u32,
    capital_allocation_bps: u64, // Basis points (10000 = 100%)
}

/// Snapshot of vault state for RL agent
public struct VaultSnapshot has copy, drop {
    total_value_0: u64,
    total_value_1: u64,
    active_position_count: u64,
    idle_capital_0: u64,
    idle_capital_1: u64,
    total_shares: u128,
    last_rebalance_time: u64,
}

// ===== Events =====

public struct VaultCreated has copy, drop {
    vault_id: ID,
    pool_id: ID,
    agent: address,
}

public struct Deposited has copy, drop {
    vault_id: ID,
    user: address,
    amount_0: u64,
    amount_1: u64,
    shares_minted: u128,
    total_shares: u128,
}

public struct Withdrawn has copy, drop {
    vault_id: ID,
    user: address,
    shares_burned: u128,
    amount_0: u64,
    amount_1: u64,
    total_shares: u128,
}

public struct PositionsRebalanced has copy, drop {
    vault_id: ID,
    old_position_count: u64,
    new_position_count: u64,
    timestamp: u64,
    gas_estimate: u64,
}

public struct PerformanceUpdated has copy, drop {
    vault_id: ID,
    total_value_usd: u64,
    fees_earned_0: u64,
    fees_earned_1: u64,
    apr_estimate: u64, // basis points
}

// ===== Initialization =====

/// Create a new adaptive vault
public fun create_vault<Token0, Token1>(
    pool_id: ID,
    agent_address: address,
    min_rebalance_interval_ms: u64,
    ctx: &mut TxContext,
) {
    let vault_id_inner = object::new(ctx);
    let vault_id = object::uid_to_inner(&vault_id_inner);

    let vault = AdaptiveVault<Token0, Token1> {
        id: vault_id_inner,
        pool_id,
        total_shares: 0,
        user_shares: table::new(ctx),
        active_positions: vector::empty(),
        position_nfts: table::new(ctx),
        authorized_agent: agent_address,
        agent_performance_score: 10000, // Start at 100%
        total_fees_earned_0: 0,
        total_fees_earned_1: 0,
        total_rebalances: 0,
        last_rebalance_time: 0,
        reserve_0: balance::zero(),
        reserve_1: balance::zero(),
        paused: false,
        min_rebalance_interval_ms,
        constraints: AgentConstraints {
            max_positions: 5,
            min_positions: 1,
            max_single_position_bps: 5000, // 50%
            max_range_width_ticks: 1000,
            min_range_width_ticks: 60,
            max_distance_from_current_tick: 500,
        },
    };

    // Create admin cap
    let admin_cap = VaultAdminCap {
        id: object::new(ctx),
        vault_id,
    };

    event::emit(VaultCreated {
        vault_id,
        pool_id,
        agent: agent_address,
    });

    transfer::transfer(admin_cap, tx_context::sender(ctx));
    transfer::share_object(vault);
}

// ===== User Functions: Deposit & Withdraw =====

/// Deposit tokens and receive vault shares
public entry fun deposit<Token0, Token1>(
    vault: &mut AdaptiveVault<Token0, Token1>,
    pool: &Pool<Token0, Token1>,
    coin_0: Coin<Token0>,
    coin_1: Coin<Token1>,
    ctx: &mut TxContext,
) {
    assert!(!vault.paused, E_VAULT_PAUSED);

    let amount_0 = coin::value(&coin_0);
    let amount_1 = coin::value(&coin_1);

    assert!(amount_0 >= MIN_DEPOSIT || amount_1 >= MIN_DEPOSIT, E_MIN_DEPOSIT);

    // Calculate shares to mint
    let shares = if (vault.total_shares == 0) {
        // First deposit: shares = sqrt(amount0 * amount1)
        // This prevents first depositor attacks
        let product = (amount_0 as u128) * (amount_1 as u128);
        sqrt_u128(product)
    } else {
        // Subsequent deposits: shares proportional to value added
        calculate_shares_for_deposit(vault, pool, amount_0, amount_1)
    };

    // Add to reserves
    balance::join(&mut vault.reserve_0, coin::into_balance(coin_0));
    balance::join(&mut vault.reserve_1, coin::into_balance(coin_1));

    // Mint shares
    vault.total_shares = vault.total_shares + shares;

    let user = tx_context::sender(ctx);
    if (table::contains(&vault.user_shares, user)) {
        let user_shares = table::borrow_mut(&mut vault.user_shares, user);
        *user_shares = *user_shares + shares;
    } else {
        table::add(&mut vault.user_shares, user, shares);
    };

    event::emit(Deposited {
        vault_id: object::id(vault),
        user,
        amount_0,
        amount_1,
        shares_minted: shares,
        total_shares: vault.total_shares,
    });
}

/// Withdraw tokens by burning shares
public entry fun withdraw<Token0, Token1>(
    vault: &mut AdaptiveVault<Token0, Token1>,
    pool: &mut Pool<Token0, Token1>,
    shares_to_burn: u128,
    ctx: &mut TxContext,
) {
    let user = tx_context::sender(ctx);

    // Verify user has shares
    assert!(table::contains(&vault.user_shares, user), E_NO_SHARES);

    {
        let user_shares = table::borrow_mut(&mut vault.user_shares, user);
        assert!(*user_shares >= shares_to_burn, E_INSUFFICIENT_SHARES);

        // Burn user shares
        *user_shares = *user_shares - shares_to_burn;
    };

    // Calculate withdrawal amounts (proportional to shares)
    let (withdraw_0, withdraw_1) = calculate_withdrawal_amounts(
        vault,
        pool,
        shares_to_burn,
    );

    // Burn shares
    vault.total_shares = vault.total_shares - shares_to_burn;

    // If needed, liquidate positions to honor withdrawal
    ensure_liquidity_for_withdrawal(vault, pool, withdraw_0, withdraw_1, ctx);

    // Transfer tokens
    let coin_0 = coin::take(&mut vault.reserve_0, withdraw_0, ctx);
    let coin_1 = coin::take(&mut vault.reserve_1, withdraw_1, ctx);

    transfer::public_transfer(coin_0, user);
    transfer::public_transfer(coin_1, user);

    event::emit(Withdrawn {
        vault_id: object::id(vault),
        user,
        shares_burned: shares_to_burn,
        amount_0: withdraw_0,
        amount_1: withdraw_1,
        total_shares: vault.total_shares,
    });
}

// ===== RL Agent Functions: Rebalancing =====

/// RL agent rebalances positions (main function)
public entry fun rebalance<Token0, Token1>(
    vault: &mut AdaptiveVault<Token0, Token1>,
    pool: &mut Pool<Token0, Token1>,
    registry: &mut PositionRegistry,
    // new_position_configs: vector<PositionConfig>,
    new_position_tick_low: vector<u32>,
    new_position_tick_high: vector<u32>,
    new_position_liquidity: vector<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(
        vector::length(&new_position_tick_low) == vector::length(&new_position_tick_high),
        E_INVALID_POSITION_CONFIG,
    );
    assert!(
        vector::length(&new_position_tick_low) == vector::length(&new_position_liquidity),
        E_INVALID_POSITION_CONFIG,
    );

    let mut new_position_configs = vector::empty();
    let mut i = 0;
    let len = vector::length(&new_position_tick_low);
    while (i < len) {
        vector::push_back(
            &mut new_position_configs,
            PositionConfig {
                tick_lower: new_position_tick_low[i],
                tick_upper: new_position_tick_high[i],
                capital_allocation_bps: new_position_liquidity[i],
            },
        );
        i = i + 1;
    };

    // for (i in 0..vector::length(&new_position_tick_low)) {
    //     vector::push_back(&mut new_position_configs, PositionConfig {
    //         tick_lower: new_position_tick_low[i],
    //         tick_upper: new_position_tick_high[i],
    //         capital_allocation_bps: new_position_liquidity[i],
    //     });
    // };

    // Authorization check
    assert!(tx_context::sender(ctx) == vault.authorized_agent, E_UNAUTHORIZED);
    assert!(!vault.paused, E_VAULT_PAUSED);

    // Rate limiting
    let current_time = clock::timestamp_ms(clock);
    if (vault.last_rebalance_time > 0) {
        assert!(
            current_time >= vault.last_rebalance_time + vault.min_rebalance_interval_ms,
            E_REBALANCE_TOO_SOON,
        );
    };

    // Validate proposed positions against constraints
    validate_position_configs(vault, pool, &new_position_configs);

    let old_position_count = vector::length(&vault.active_positions);

    // Step 1: Close all existing positions
    close_all_positions(vault, pool, ctx);

    // Step 2: Open new positions
    open_new_positions(vault, pool, registry, new_position_configs, ctx);

    // Update state
    vault.total_rebalances = vault.total_rebalances + 1;
    vault.last_rebalance_time = current_time;

    event::emit(PositionsRebalanced {
        vault_id: object::id(vault),
        old_position_count,
        new_position_count: vector::length(&vault.active_positions),
        timestamp: current_time,
        gas_estimate: 0, // Could estimate based on position count
    });
}

/// Close all active positions and collect fees
fun close_all_positions<Token0, Token1>(
    vault: &mut AdaptiveVault<Token0, Token1>,
    pool: &mut Pool<Token0, Token1>,
    ctx: &mut TxContext,
) {
    let mut i = 0;
    let len = vector::length(&vault.active_positions);

    while (i < len) {
        let token_id = *vector::borrow(&vault.active_positions, i);
        let nft = table::borrow_mut(&mut vault.position_nfts, token_id);

        let liquidity = position::liquidity(nft);

        if (liquidity > 0) {
            // Remove all liquidity
            let (amount_0, amount_1) = pool::decrease_liquidity(
                pool,
                nft,
                liquidity,
                ctx,
            );

            // Collect fees and principal
            let (coin_0, coin_1) = pool::collect(pool, nft, 0, 0, ctx);

            let fees_0 = coin::value(&coin_0);
            let fees_1 = coin::value(&coin_1);

            // Track fees earned
            vault.total_fees_earned_0 = vault.total_fees_earned_0 + fees_0;
            vault.total_fees_earned_1 = vault.total_fees_earned_1 + fees_1;

            // Add to reserves
            balance::join(&mut vault.reserve_0, coin::into_balance(coin_0));
            balance::join(&mut vault.reserve_1, coin::into_balance(coin_1));
        };

        i = i + 1;
    };

    // Burn old NFTs and clear tracking
    i = 0;
    while (i < len) {
        let token_id = *vector::borrow(&vault.active_positions, i);
        let nft = table::remove(&mut vault.position_nfts, token_id);

        // Burn the NFT
        pool::burn_position(pool, nft, ctx);

        i = i + 1;
    };

    // Clear active positions vector
    vault.active_positions = vector::empty();
}

/// Open new positions based on RL strategy
fun open_new_positions<Token0, Token1>(
    vault: &mut AdaptiveVault<Token0, Token1>,
    pool: &mut Pool<Token0, Token1>,
    registry: &mut PositionRegistry,
    configs: vector<PositionConfig>,
    ctx: &mut TxContext,
) {
    let mut i = 0;
    let len = vector::length(&configs);

    let total_reserve_0 = balance::value(&vault.reserve_0);
    let total_reserve_1 = balance::value(&vault.reserve_1);

    while (i < len) {
        let config = vector::borrow(&configs, i);

        // Calculate capital allocation
        let amount_0 =
            ((total_reserve_0 as u128) * (config.capital_allocation_bps as u128) / 10000) as u64;
        let amount_1 =
            ((total_reserve_1 as u128) * (config.capital_allocation_bps as u128) / 10000) as u64;

        if (amount_0 > 0 || amount_1 > 0) {
            // Take from reserves
            let coin_0 = coin::take(&mut vault.reserve_0, amount_0, ctx);
            let coin_1 = coin::take(&mut vault.reserve_1, amount_1, ctx);

            // Mint position
            let (actual_0, actual_1, liquidity, nft) = pool::mint(
                pool,
                registry,
                config.tick_lower,
                config.tick_upper,
                amount_0,
                amount_1,
                0, // min amounts (agent should calculate this)
                0,
                coin_0,
                coin_1,
                vault.authorized_agent, // NFT goes to agent address temporarily
                ctx,
            );

            let token_id = position::token_id(&nft);

            // Store the token_id and the NFT
            vector::push_back(&mut vault.active_positions, token_id);
            table::add(&mut vault.position_nfts, token_id, nft);
        };

        i = i + 1;
    };
}

/// Validate position configs against constraints
fun validate_position_configs<Token0, Token1>(
    vault: &AdaptiveVault<Token0, Token1>,
    pool: &Pool<Token0, Token1>,
    configs: &vector<PositionConfig>,
) {
    let num_positions = vector::length(configs);
    let constraints = &vault.constraints;

    // Check position count
    assert!(num_positions >= constraints.min_positions, E_TOO_MANY_POSITIONS);
    assert!(num_positions <= constraints.max_positions, E_TOO_MANY_POSITIONS);

    // Get current tick
    let (_, current_tick, _) = pool::get_slot0(pool);

    let mut total_allocation = 0u64;
    let mut i = 0;

    while (i < num_positions) {
        let config = vector::borrow(configs, i);

        // Validate allocation
        assert!(
            config.capital_allocation_bps <= constraints.max_single_position_bps,
            E_INVALID_ALLOCATION,
        );

        // Validate range width
        let range_width = config.tick_upper - config.tick_lower;
        assert!(range_width >= constraints.min_range_width_ticks, E_INVALID_POSITION_CONFIG);
        assert!(range_width <= constraints.max_range_width_ticks, E_INVALID_POSITION_CONFIG);

        // Validate distance from current price
        let distance_lower = if (config.tick_lower > current_tick) {
            config.tick_lower - current_tick
        } else {
            current_tick - config.tick_lower
        };

        let distance_upper = if (config.tick_upper > current_tick) {
            config.tick_upper - current_tick
        } else {
            current_tick - config.tick_upper
        };

        assert!(
            distance_lower <= constraints.max_distance_from_current_tick,
            E_INVALID_POSITION_CONFIG,
        );
        assert!(
            distance_upper <= constraints.max_distance_from_current_tick,
            E_INVALID_POSITION_CONFIG,
        );

        total_allocation = total_allocation + config.capital_allocation_bps;
        i = i + 1;
    };

    // Total allocation should be ~100% (allow 1% tolerance)
    assert!(total_allocation >= 9900 && total_allocation <= 10100, E_INVALID_ALLOCATION);
}

// ===== Helper Functions =====

/// Calculate shares to mint for a deposit
fun calculate_shares_for_deposit<Token0, Token1>(
    vault: &AdaptiveVault<Token0, Token1>,
    pool: &Pool<Token0, Token1>,
    amount_0: u64,
    amount_1: u64,
): u128 {
    let (total_value_0, total_value_1) = calculate_total_vault_value(vault, pool);

    // Calculate deposit value as proportion of total value
    // shares = (deposit_value / total_value) * total_shares

    let deposit_value = (amount_0 as u128) + (amount_1 as u128); // Simplified
    let total_value = (total_value_0 as u128) + (total_value_1 as u128);

    if (total_value == 0) {
        sqrt_u128((amount_0 as u128) * (amount_1 as u128))
    } else {
        (deposit_value * vault.total_shares) / total_value
    }
}

/// Calculate withdrawal amounts for shares
fun calculate_withdrawal_amounts<Token0, Token1>(
    vault: &AdaptiveVault<Token0, Token1>,
    pool: &Pool<Token0, Token1>,
    shares: u128,
): (u64, u64) {
    let (total_value_0, total_value_1) = calculate_total_vault_value(vault, pool);

    let withdraw_0 = ((total_value_0 as u128) * shares / vault.total_shares) as u64;
    let withdraw_1 = ((total_value_1 as u128) * shares / vault.total_shares) as u64;

    (withdraw_0, withdraw_1)
}

/// Calculate total vault value (reserves + positions)
fun calculate_total_vault_value<Token0, Token1>(
    vault: &AdaptiveVault<Token0, Token1>,
    pool: &Pool<Token0, Token1>,
): (u64, u64) {
    let mut total_0 = balance::value(&vault.reserve_0);
    let mut total_1 = balance::value(&vault.reserve_1);

    // Get current pool price
    let (sqrt_price, _, _) = pool::get_slot0(pool);

    // Add value locked in positions
    let mut i = 0;
    let len = vector::length(&vault.active_positions);

    while (i < len) {
        let token_id = *vector::borrow(&vault.active_positions, i);
        // We can get position data either from the NFT or from the Pool
        // Getting from pool ensures we see the latest fee growth etc.
        let (tick_lower, tick_upper, liquidity, _, _, owed0, owed1) = pool::get_position_data(
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
            total_0 = total_0 + (liquidity_math::get_amount0(&amounts) as u64);
            total_1 = total_1 + (liquidity_math::get_amount1(&amounts) as u64);
        };

        // Add pending fees
        total_0 = total_0 + owed0;
        total_1 = total_1 + owed1;

        i = i + 1;
    };

    (total_0, total_1)
}

/// Ensure vault has enough liquidity for withdrawal
fun ensure_liquidity_for_withdrawal<Token0, Token1>(
    vault: &mut AdaptiveVault<Token0, Token1>,
    pool: &mut Pool<Token0, Token1>,
    needed_0: u64,
    needed_1: u64,
    ctx: &mut TxContext,
) {
    let mut available_0 = balance::value(&vault.reserve_0);
    let mut available_1 = balance::value(&vault.reserve_1);

    // If reserves sufficient, no action needed
    if (available_0 >= needed_0 && available_1 >= needed_1) {
        return
    };

    // Otherwise, need to partially liquidate positions
    // Simplified: close positions until we have enough
    // In production, you'd be more strategic about which positions to close

    let mut i = 0;
    let len = vector::length(&vault.active_positions);

    while (i < len && (available_0 < needed_0 || available_1 < needed_1)) {
        let token_id = *vector::borrow(&vault.active_positions, i);
        let nft = table::borrow_mut(&mut vault.position_nfts, token_id);

        let liquidity = position::liquidity(nft);
        if (liquidity > 0) {
            pool::decrease_liquidity(pool, nft, liquidity, ctx);
            let (coin_0, coin_1) = pool::collect(pool, nft, 0, 0, ctx);

            balance::join(&mut vault.reserve_0, coin::into_balance(coin_0));
            balance::join(&mut vault.reserve_1, coin::into_balance(coin_1));

            available_0 = balance::value(&vault.reserve_0);
            available_1 = balance::value(&vault.reserve_1);
        };

        i = i + 1;
    };
}

/// Square root approximation
fun sqrt_u128(x: u128): u128 {
    if (x == 0) return 0;

    let mut z = x;
    let mut y = (x + 1) / 2;

    while (y < z) {
        z = y;
        y = (x / y + y) / 2;
    };

    z
}

// ===== View Functions for RL Agent =====

/// Get vault snapshot for RL agent decision-making
public fun get_vault_snapshot<Token0, Token1>(
    vault: &AdaptiveVault<Token0, Token1>,
    pool: &Pool<Token0, Token1>,
): VaultSnapshot {
    let (total_0, total_1) = calculate_total_vault_value(vault, pool);

    VaultSnapshot {
        total_value_0: total_0,
        total_value_1: total_1,
        active_position_count: vector::length(&vault.active_positions),
        idle_capital_0: balance::value(&vault.reserve_0),
        idle_capital_1: balance::value(&vault.reserve_1),
        total_shares: vault.total_shares,
        last_rebalance_time: vault.last_rebalance_time,
    }
}

/// Get user's share balance
public fun get_user_shares<Token0, Token1>(
    vault: &AdaptiveVault<Token0, Token1>,
    user: address,
): u128 {
    if (table::contains(&vault.user_shares, user)) {
        *table::borrow(&vault.user_shares, user)
    } else {
        0
    }
}

// ===== Admin Functions =====

/// Pause vault (emergency)
public entry fun pause_vault<Token0, Token1>(
    vault: &mut AdaptiveVault<Token0, Token1>,
    _admin_cap: &VaultAdminCap,
) {
    vault.paused = true;
}

/// Unpause vault
public entry fun unpause_vault<Token0, Token1>(
    vault: &mut AdaptiveVault<Token0, Token1>,
    _admin_cap: &VaultAdminCap,
) {
    vault.paused = false;
}

/// Update agent address
public entry fun update_agent<Token0, Token1>(
    vault: &mut AdaptiveVault<Token0, Token1>,
    new_agent: address,
    _admin_cap: &VaultAdminCap,
) {
    vault.authorized_agent = new_agent;
}

/// Update constraints
public entry fun update_constraints<Token0, Token1>(
    vault: &mut AdaptiveVault<Token0, Token1>,
    max_positions: u64,
    min_positions: u64,
    max_single_position_bps: u64,
    max_range_width_ticks: u32,
    min_range_width_ticks: u32,
    max_distance_from_current_tick: u32,
    _admin_cap: &VaultAdminCap,
) {
    vault.constraints =
        AgentConstraints {
            max_positions,
            min_positions,
            max_single_position_bps,
            max_range_width_ticks,
            min_range_width_ticks,
            max_distance_from_current_tick,
        };
}

#[test_only]
public fun create_vault_for_testing<Token0, Token1>(
    pool_id: ID,
    agent: address,
    ctx: &mut TxContext,
) {
    create_vault<Token0, Token1>(pool_id, agent, 60000, ctx);
}
