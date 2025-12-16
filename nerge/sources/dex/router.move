module protocol::acl_router;

use acl_dex_core::pool::{Self as pool, Pool};
use protocol::batch_auction::{Self, BatchAuction};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::event;
use sui::object::{Self, UID, ID};
use sui::transfer;
use sui::tx_context::{Self, TxContext};

// ==================== Structs ====================

/// Router configuration
public struct RouterConfig has key {
    id: UID,
    /// Maximum number of hops allowed
    max_hops: u64,
    /// Minimum amount out for dust prevention
    min_amount_out: u64,
    /// Default slippage tolerance (basis points)
    default_slippage_bps: u64,
}

/// Swap path for multi-hop routing
public struct SwapPath has copy, drop, store {
    /// Pool IDs to route through
    pool_ids: vector<ID>,
    /// Expected output amount
    expected_out: u64,
    /// Total fee (basis points)
    total_fee_bps: u64,
}

/// Route calculation result
public struct RouteQuote has copy, drop {
    /// Best path found
    path: SwapPath,
    /// Amount in
    amount_in: u64,
    /// Expected amount out
    amount_out: u64,
    /// Price impact (basis points)
    price_impact_bps: u64,
    /// Minimum amount out after slippage
    min_amount_out: u64,
}

// ==================== Events ====================

public struct SwapExecuted has copy, drop {
    trader: address,
    token_in: vector<u8>,
    token_out: vector<u8>,
    amount_in: u64,
    amount_out: u64,
    num_hops: u64,
}

public struct MultiHopSwapExecuted has copy, drop {
    trader: address,
    path: vector<ID>,
    amount_in: u64,
    amount_out: u64,
    price_impact_bps: u64,
}

// ==================== Core Functions ====================

/// Initialize router configuration
entry fun init_router(
    max_hops: u64,
    min_amount_out: u64,
    default_slippage_bps: u64,
    ctx: &mut TxContext,
) {
    assert!(max_hops > 0 && max_hops <= 5, E_INVALID_MAX_HOPS);
    assert!(default_slippage_bps <= 10000, E_INVALID_SLIPPAGE);

    let config = RouterConfig {
        id: object::new(ctx),
        max_hops,
        min_amount_out,
        default_slippage_bps,
    };

    transfer::share_object(config);
}

/// Single-hop swap: token X -> token Y
public fun swap_exact_input<X, Y>(
    pool: &mut Pool<X, Y>,
    coin_in: Coin<X>,
    min_amount_out: u64,
    ctx: &mut TxContext,
): Coin<Y> {
    let amount_in = coin::value(&coin_in);
    assert!(amount_in > 0, E_ZERO_AMOUNT);

    // Use pool's swap function
    let coin_out = pool::swap_exact_input(pool, coin_in, min_amount_out, ctx);

    event::emit(SwapExecuted {
        trader: tx_context::sender(ctx),
        token_in: b"X",
        token_out: b"Y",
        amount_in,
        amount_out: coin::value(&coin_out),
        num_hops: 1,
    });

    coin_out
}

/// Two-hop swap: X -> Y -> Z
public fun swap_exact_input_two_hop<X, Y, Z>(
    pool_xy: &mut Pool<X, Y>,
    pool_yz: &mut Pool<Y, Z>,
    coin_in: Coin<X>,
    min_amount_out: u64,
    ctx: &mut TxContext,
): Coin<Z> {
    let amount_in = coin::value(&coin_in);
    assert!(amount_in > 0, E_ZERO_AMOUNT);

    // First hop: X -> Y
    let coin_y = pool::swap_exact_input(pool_xy, coin_in, 0, ctx);

    // Second hop: Y -> Z
    let coin_z = pool::swap_exact_input(pool_yz, coin_y, min_amount_out, ctx);
    let amount_out = coin::value(&coin_z);

    event::emit(MultiHopSwapExecuted {
        trader: tx_context::sender(ctx),
        path: vector[object::id(pool_xy), object::id(pool_yz)],
        amount_in,
        amount_out,
        price_impact_bps: calculate_price_impact(amount_in, amount_out),
    });

    coin_z
}

/// Three-hop swap: A -> B -> C -> D
public fun swap_exact_input_three_hop<A, B, C, D>(
    pool_ab: &mut Pool<A, B>,
    pool_bc: &mut Pool<B, C>,
    pool_cd: &mut Pool<C, D>,
    coin_in: Coin<A>,
    min_amount_out: u64,
    ctx: &mut TxContext,
): Coin<D> {
    let amount_in = coin::value(&coin_in);
    assert!(amount_in > 0, E_ZERO_AMOUNT);

    // First hop: A -> B
    let coin_b = pool::swap_exact_input(pool_ab, coin_in, 0, ctx);

    // Second hop: B -> C
    let coin_c = pool::swap_exact_input(pool_bc, coin_b, 0, ctx);

    // Third hop: C -> D
    let coin_d = pool::swap_exact_input(pool_cd, coin_c, min_amount_out, ctx);
    let amount_out = coin::value(&coin_d);

    event::emit(MultiHopSwapExecuted {
        trader: tx_context::sender(ctx),
        path: vector[object::id(pool_ab), object::id(pool_bc), object::id(pool_cd)],
        amount_in,
        amount_out,
        price_impact_bps: calculate_price_impact(amount_in, amount_out),
    });

    coin_d
}

/// Swap exact output: user wants exact amount out, pays variable amount in
/// Single hop version
public fun swap_exact_output<X, Y>(
    pool: &mut Pool<X, Y>,
    mut coin_in: Coin<X>,
    exact_amount_out: u64,
    max_amount_in: u64,
    ctx: &mut TxContext,
): (Coin<Y>, Coin<X>) {
    let amount_in_available = coin::value(&coin_in);
    assert!(amount_in_available > 0, E_ZERO_AMOUNT);
    assert!(exact_amount_out > 0, E_ZERO_AMOUNT);

    // Calculate required input
    let required_in = get_amount_in(pool, exact_amount_out, true);
    assert!(required_in <= max_amount_in, E_EXCESSIVE_INPUT_AMOUNT);
    assert!(required_in <= amount_in_available, E_INSUFFICIENT_INPUT_AMOUNT);

    // Split coins
    let coin_to_swap = coin::split(&mut coin_in, required_in, ctx);

    // Execute swap
    let coin_out = pool::swap_exact_input(pool, coin_to_swap, exact_amount_out, ctx);

    event::emit(SwapExecuted {
        trader: tx_context::sender(ctx),
        token_in: b"X",
        token_out: b"Y",
        amount_in: required_in,
        amount_out: coin::value(&coin_out),
        num_hops: 1,
    });

    // Return output and remaining input
    (coin_out, coin_in)
}

/// Submit swap to batch auction (MEV-resistant)
entry fun swap_via_batch<X, Y>(
    auction: &mut BatchAuction<X, Y>,
    coin_in: Coin<X>,
    min_amount_out: u64,
    max_slippage_bps: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(max_slippage_bps <= 10000, E_INVALID_SLIPPAGE);

    let _receipt = batch_auction::submit_order(
        auction,
        coin_in,
        min_amount_out,
        max_slippage_bps,
        clock,
        ctx,
    );

    // Receipt can be stored or returned to user
    transfer::public_transfer(_receipt, tx_context::sender(ctx));
}

// ==================== View Functions ====================

/// Get quote for single-hop swap
public fun get_quote_single_hop<X, Y>(pool: &Pool<X, Y>, amount_in: u64, is_x_to_y: bool): u64 {
    pool::get_amount_out(pool, amount_in, is_x_to_y)
}

// Alias for test compatibility
public fun quote_single_hop<X, Y>(pool: &Pool<X, Y>, amount_in: u64, is_x_to_y: bool): u64 {
    get_quote_single_hop(pool, amount_in, is_x_to_y)
}

// Alias for single-hop swap
public fun swap_exact_input_single_hop<X, Y>(
    pool: &mut Pool<X, Y>,
    coin_in: Coin<X>,
    min_amount_out: u64,
    ctx: &mut TxContext,
): Coin<Y> {
    swap_exact_input(pool, coin_in, min_amount_out, ctx)
}

/// Get quote for two-hop swap
public fun get_quote_two_hop<X, Y, Z>(
    pool_xy: &Pool<X, Y>,
    pool_yz: &Pool<Y, Z>,
    amount_in: u64,
): u64 {
    // First hop: X -> Y
    let amount_y = pool::get_amount_out(pool_xy, amount_in, true);

    // Second hop: Y -> Z
    pool::get_amount_out(pool_yz, amount_y, true)
}

// Alias for test compatibility
public fun quote_two_hop<X, Y, Z>(pool_xy: &Pool<X, Y>, pool_yz: &Pool<Y, Z>, amount_in: u64): u64 {
    get_quote_two_hop(pool_xy, pool_yz, amount_in)
}

/// Get quote for three-hop swap
public fun get_quote_three_hop<A, B, C, D>(
    pool_ab: &Pool<A, B>,
    pool_bc: &Pool<B, C>,
    pool_cd: &Pool<C, D>,
    amount_in: u64,
): u64 {
    // First hop: A -> B
    let amount_b = pool::get_amount_out(pool_ab, amount_in, true);

    // Second hop: B -> C
    let amount_c = pool::get_amount_out(pool_bc, amount_b, true);

    // Third hop: C -> D
    pool::get_amount_out(pool_cd, amount_c, true)
}

/// Calculate required input for exact output
public fun get_amount_in<X, Y>(pool: &Pool<X, Y>, amount_out: u64, is_x_to_y: bool): u64 {
    let (reserve_in, reserve_out) = if (is_x_to_y) {
        pool::get_reserves(pool)
    } else {
        let (rx, ry) = pool::get_reserves(pool);
        (ry, rx)
    };

    // Calculate required input using constant product formula
    // amount_in = (reserve_in * amount_out) / (reserve_out - amount_out) + 1
    assert!(amount_out < reserve_out, E_INSUFFICIENT_LIQUIDITY);

    let numerator = (reserve_in as u128) * (amount_out as u128) * 10000;
    let denominator = ((reserve_out - amount_out) as u128) * 9970; // Assuming 0.3% fee

    ((numerator / denominator) as u64) + 1
}

/// Calculate price impact in basis points
public fun calculate_price_impact(amount_in: u64, amount_out: u64): u64 {
    if (amount_in == 0 || amount_out == 0) {
        return 0
    };

    // Calculate execution price: amount_out / amount_in
    // Price impact = |execution_price - spot_price| / spot_price * 10000
    // Simplified version: compare execution ratio to 1:1
    // In production, this should fetch actual spot price from pool

    let execution_ratio = (amount_out as u128) * 10000 / (amount_in as u128);

    // Return deviation from expected 1:1 ratio in basis points
    // This is a conservative approximation
    if (execution_ratio > 10000) {
        ((execution_ratio - 10000) as u64)
    } else {
        ((10000 - execution_ratio) as u64)
    }
}

/// Get optimal route between two tokens (view function for off-chain)
/// This would typically be calculated off-chain and the result passed to swap functions
public fun estimate_best_route<X, Y>(
    pool: &Pool<X, Y>,
    amount_in: u64,
    slippage_bps: u64,
): (u64, u64) {
    let amount_out = pool::get_amount_out(pool, amount_in, true);
    let min_amount_out = amount_out * (10000 - slippage_bps) / 10000;

    (amount_out, min_amount_out)
}

// ==================== Helper Functions ====================

/// Apply slippage tolerance to amount
fun apply_slippage(amount: u64, slippage_bps: u64): u64 {
    amount * (10000 - slippage_bps) / 10000
}

/// Check if swap is profitable after fees
fun is_swap_profitable(amount_in: u64, amount_out: u64, min_profit_bps: u64): bool {
    if (amount_in == 0) return false;

    let profit_bps = ((amount_out as u128) * 10000 / (amount_in as u128)) as u64;
    profit_bps >= (10000 + min_profit_bps)
}

// ==================== Advanced Routing ====================

/// Split trade across multiple pools for better execution
/// This implements a simple split between two pools
public fun swap_split_route<X, Y>(
    pool1: &mut Pool<X, Y>,
    pool2: &mut Pool<X, Y>,
    mut coin_in: Coin<X>,
    split_ratio_pool1_bps: u64, // Basis points to route through pool1
    min_total_out: u64,
    ctx: &mut TxContext,
): Coin<Y> {
    assert!(split_ratio_pool1_bps <= 10000, E_INVALID_SPLIT_RATIO);

    let total_in = coin::value(&coin_in);
    let amount_pool1 = total_in * split_ratio_pool1_bps / 10000;
    let amount_pool2 = total_in - amount_pool1;

    // Split input
    let coin_pool1 = if (amount_pool1 > 0) {
        coin::split(&mut coin_in, amount_pool1, ctx)
    } else {
        coin::zero<X>(ctx)
    };

    // Execute swaps
    let mut coin_out1 = if (coin::value(&coin_pool1) > 0) {
        pool::swap_exact_input(pool1, coin_pool1, 0, ctx)
    } else {
        coin::destroy_zero(coin_pool1);
        coin::zero<Y>(ctx)
    };

    let coin_out2 = if (coin::value(&coin_in) > 0) {
        pool::swap_exact_input(pool2, coin_in, 0, ctx)
    } else {
        coin::destroy_zero(coin_in);
        coin::zero<Y>(ctx)
    };

    // Merge outputs
    coin::join(&mut coin_out1, coin_out2);

    let total_out = coin::value(&coin_out1);
    assert!(total_out >= min_total_out, E_SLIPPAGE_EXCEEDED);

    event::emit(SwapExecuted {
        trader: tx_context::sender(ctx),
        token_in: b"X",
        token_out: b"Y",
        amount_in: total_in,
        amount_out: total_out,
        num_hops: 1,
    });

    coin_out1
}

// ==================== Error Codes ====================

const E_ZERO_AMOUNT: u64 = 300;
const E_INVALID_SLIPPAGE: u64 = 301;
const E_SLIPPAGE_EXCEEDED: u64 = 302;
const E_INVALID_MAX_HOPS: u64 = 303;
const E_EXCESSIVE_INPUT_AMOUNT: u64 = 304;
const E_INSUFFICIENT_INPUT_AMOUNT: u64 = 305;
const E_INSUFFICIENT_LIQUIDITY: u64 = 306;
const E_INVALID_SPLIT_RATIO: u64 = 307;
const E_INVALID_PATH: u64 = 308;
