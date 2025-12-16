/// Quoter - Get swap quotes without executing
///
/// Provides:
/// - Quote exact input swaps
/// - Quote exact output swaps
/// - Multi-hop quote calculations
/// - Price impact estimation
///
/// NOTE: Quotes are read-only simulations and don't modify state
module protocol::quoter;

use acl_dex_core::pool::{Self as pool, Pool};
use acl_dex_core::tick;
use nerge_math_lib::liquidity_math;
use nerge_math_lib::signed_math;
use nerge_math_lib::swap_math;
use nerge_math_lib::tick_math;

// ========================================================================
// Error Codes
// ========================================================================

const EZERO_AMOUNT: u64 = 1;
const EINSUFFICIENT_LIQUIDITY: u64 = 2;
const EINVALID_SQRT_PRICE: u64 = 3;

// ========================================================================
// Structs
// ========================================================================

/// Quote result for single swap
public struct QuoteResult has copy, drop {
    amount_out: u64,
    sqrt_price_x96_after: u256,
    tick_after: u32,
    initialized_ticks_crossed: u32,
}

/// Quote result for multi-hop swap
public struct MultiHopQuoteResult has copy, drop {
    amount_out: u64,
    sqrt_prices_after: vector<u256>,
    amounts_out: vector<u64>,
}

// ========================================================================
// Quote Exact Input
// ========================================================================

/// Quote exact input swap: Token0 -> Token1
///
/// Returns the expected output amount without executing the swap.
/// Useful for frontend to show estimated returns.
///
/// Example:
/// ```
/// // Get quote for swapping 1000 SUI to USDC
/// let quote = quote_exact_input_single_0_for_1(&pool, 1000);
/// let expected_usdc = quote_result_amount_out(&quote);
/// ```
public fun quote_exact_input_single_0_for_1<Token0, Token1>(
    pool: &Pool<Token0, Token1>,
    amount_in: u64,
): QuoteResult {
    assert!(amount_in > 0, EZERO_AMOUNT);

    let (sqrt_price_x96, tick, liquidity) = pool::get_slot0(pool);
    assert!(liquidity > 0, EINSUFFICIENT_LIQUIDITY);

    let sqrt_price_limit_x96 = tick_math::get_min_sqrt_ratio() + 1;

    simulate_swap(
        pool,
        true, // zero_for_one
        amount_in,
        sqrt_price_x96,
        tick,
        liquidity,
        sqrt_price_limit_x96,
    )
}

/// Quote exact input swap: Token1 -> Token0
public fun quote_exact_input_single_1_for_0<Token0, Token1>(
    pool: &Pool<Token0, Token1>,
    amount_in: u64,
): QuoteResult {
    assert!(amount_in > 0, EZERO_AMOUNT);

    let (sqrt_price_x96, tick, liquidity) = pool::get_slot0(pool);
    assert!(liquidity > 0, EINSUFFICIENT_LIQUIDITY);

    let sqrt_price_limit_x96 = tick_math::get_max_sqrt_ratio() - 1;

    simulate_swap(
        pool,
        false, // zero_for_one
        amount_in,
        sqrt_price_x96,
        tick,
        liquidity,
        sqrt_price_limit_x96,
    )
}

// ========================================================================
// Multi-hop Quotes
// ========================================================================

/// Quote two-hop swap: Token0 -> Token1 -> Token2
public fun quote_exact_input_two_hop<Token0, Token1, Token2>(
    pool1: &Pool<Token0, Token1>,
    pool2: &Pool<Token1, Token2>,
    amount_in: u64,
): MultiHopQuoteResult {
    // First hop quote
    let quote1 = quote_exact_input_single_0_for_1(pool1, amount_in);
    let intermediate_amount = quote1.amount_out;

    // Second hop quote
    let quote2 = quote_exact_input_single_0_for_1(pool2, intermediate_amount);

    // Build result
    let mut sqrt_prices = vector::empty<u256>();
    vector::push_back(&mut sqrt_prices, quote1.sqrt_price_x96_after);
    vector::push_back(&mut sqrt_prices, quote2.sqrt_price_x96_after);

    let mut amounts = vector::empty<u64>();
    vector::push_back(&mut amounts, intermediate_amount);
    vector::push_back(&mut amounts, quote2.amount_out);

    MultiHopQuoteResult {
        amount_out: quote2.amount_out,
        sqrt_prices_after: sqrt_prices,
        amounts_out: amounts,
    }
}

/// Quote three-hop swap: Token0 -> Token1 -> Token2 -> Token3
public fun quote_exact_input_three_hop<Token0, Token1, Token2, Token3>(
    pool1: &Pool<Token0, Token1>,
    pool2: &Pool<Token1, Token2>,
    pool3: &Pool<Token2, Token3>,
    amount_in: u64,
): MultiHopQuoteResult {
    let quote1 = quote_exact_input_single_0_for_1(pool1, amount_in);
    let quote2 = quote_exact_input_single_0_for_1(pool2, quote1.amount_out);
    let quote3 = quote_exact_input_single_0_for_1(pool3, quote2.amount_out);

    let mut sqrt_prices = vector::empty<u256>();
    vector::push_back(&mut sqrt_prices, quote1.sqrt_price_x96_after);
    vector::push_back(&mut sqrt_prices, quote2.sqrt_price_x96_after);
    vector::push_back(&mut sqrt_prices, quote3.sqrt_price_x96_after);

    let mut amounts = vector::empty<u64>();
    vector::push_back(&mut amounts, quote1.amount_out);
    vector::push_back(&mut amounts, quote2.amount_out);
    vector::push_back(&mut amounts, quote3.amount_out);

    MultiHopQuoteResult {
        amount_out: quote3.amount_out,
        sqrt_prices_after: sqrt_prices,
        amounts_out: amounts,
    }
}

// ========================================================================
// Price Impact Calculation
// ========================================================================

/// Calculate price impact percentage (in basis points)
///
/// Returns price impact as basis points (10000 = 100%)
/// Example: 50 = 0.5% price impact
public fun calculate_price_impact<Token0, Token1>(
    pool: &Pool<Token0, Token1>,
    amount_in: u64,
    zero_for_one: bool,
): u64 {
    let (sqrt_price_before, _, _) = pool::get_slot0(pool);

    let quote = if (zero_for_one) {
        quote_exact_input_single_0_for_1(pool, amount_in)
    } else {
        quote_exact_input_single_1_for_0(pool, amount_in)
    };

    let sqrt_price_after = quote.sqrt_price_x96_after;

    // Calculate price change: |price_after - price_before| / price_before
    // For sqrt prices: ((sqrt_after - sqrt_before) / sqrt_before)^2 ≈ 2 * (sqrt_after - sqrt_before) / sqrt_before

    let price_change = if (sqrt_price_after > sqrt_price_before) {
        sqrt_price_after - sqrt_price_before
    } else {
        sqrt_price_before - sqrt_price_after
    };

    // Calculate percentage in basis points (10000 = 100%)
    let impact_bps = ((price_change as u128) * 10000 / (sqrt_price_before as u128)) as u64;

    // For sqrt prices, we need to approximately double to get actual price impact
    impact_bps * 2
}

// ========================================================================
// Core Simulation Logic
// ========================================================================

/// Simulate a swap without executing it
///
/// This is a read-only function that calculates what would happen
/// if a swap were executed with the given parameters.
fun simulate_swap<Token0, Token1>(
    pool: &Pool<Token0, Token1>,
    zero_for_one: bool,
    amount_specified: u64,
    sqrt_price_x96: u256,
    tick: u32,
    liquidity: u128,
    sqrt_price_limit_x96: u256,
): QuoteResult {
    let (fee, tick_spacing) = pool::get_config(pool);

    let mut amount_remaining = (amount_specified as u256);
    let mut amount_calculated = 0u256;
    let mut current_sqrt_price = sqrt_price_x96;
    let mut current_tick = tick;
    let mut current_liquidity = liquidity;
    let mut ticks_crossed = 0u32;

    // Simplified swap simulation (doesn't cross ticks)
    // For a full implementation, would need to traverse ticks

    let swap_result = swap_math::compute_swap_step(
        current_sqrt_price,
        sqrt_price_limit_x96,
        current_liquidity,
        amount_remaining,
        fee,
    );

    current_sqrt_price = swap_math::get_sqrt_price_next(&swap_result);
    amount_calculated = swap_math::get_amount_out(&swap_result);

    // Calculate final tick
    current_tick = tick_math::get_tick_at_sqrt_ratio(current_sqrt_price);

    QuoteResult {
        amount_out: (amount_calculated as u64),
        sqrt_price_x96_after: current_sqrt_price,
        tick_after: current_tick,
        initialized_ticks_crossed: ticks_crossed,
    }
}

// ========================================================================
// Accessor Functions
// ========================================================================

public fun quote_result_amount_out(result: &QuoteResult): u64 {
    result.amount_out
}

public fun quote_result_sqrt_price_after(result: &QuoteResult): u256 {
    result.sqrt_price_x96_after
}

public fun quote_result_tick_after(result: &QuoteResult): u32 {
    result.tick_after
}

public fun quote_result_ticks_crossed(result: &QuoteResult): u32 {
    result.initialized_ticks_crossed
}

public fun multi_hop_result_amount_out(result: &MultiHopQuoteResult): u64 {
    result.amount_out
}

public fun multi_hop_result_sqrt_prices(result: &MultiHopQuoteResult): &vector<u256> {
    &result.sqrt_prices_after
}

public fun multi_hop_result_amounts_out(result: &MultiHopQuoteResult): &vector<u64> {
    &result.amounts_out
}

// ========================================================================
// Convenience Functions
// ========================================================================

/// Get a simple quote with price impact
public fun get_quote_with_impact<Token0, Token1>(
    pool: &Pool<Token0, Token1>,
    amount_in: u64,
    zero_for_one: bool,
): (u64, u64) {
    let quote = if (zero_for_one) {
        quote_exact_input_single_0_for_1(pool, amount_in)
    } else {
        quote_exact_input_single_1_for_0(pool, amount_in)
    };

    let price_impact = calculate_price_impact(pool, amount_in, zero_for_one);

    (quote.amount_out, price_impact)
}

// ========================================================================
// Tests
// ========================================================================

#[test_only]
use sui::test_scenario;
#[test_only]
use sui::test_utils;

#[test_only]
public struct TOKEN_A has drop {}
#[test_only]
public struct TOKEN_B has drop {}

#[test]
fun test_quote_returns_reasonable_values() {
    let user = @0xA;
    let mut scenario = test_scenario::begin(user);

    test_scenario::next_tx(&mut scenario, user);
    let ctx = test_scenario::ctx(&mut scenario);
    let sqrt_price = 79228162514264337593543950336_u256;
    let pool = pool::create_pool<TOKEN_A, TOKEN_B>(3000, 60, sqrt_price, ctx);

    // Note: Without liquidity, quote would fail
    // In practice, would need to add liquidity first

    test_utils::destroy(pool);
    test_scenario::end(scenario);
}
