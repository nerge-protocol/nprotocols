/// Liquidity Math for Uniswap v3-style DEX
///
/// Core Concepts:
/// - Liquidity (L) represents the amount of virtual tokens in a position
/// - Real liquidity is distributed across price ranges (concentrated liquidity)
/// - Formulas relate liquidity to token amounts and price ranges
///
/// Key Relationships:
/// - amount0 = L * (1/√P_b - 1/√P_a)  [token0 when price below range]
/// - amount1 = L * (√P_b - √P_a)      [token1 when price above range]
/// - When price is within range, both formulas apply partially
///
/// Token Amounts ↔ Liquidity Conversions:
/// - L = amount0 / (1/√P_b - 1/√P_a)
/// - L = amount1 / (√P_b - √P_a)
module nerge_math_lib::liquidity_math;

use nerge_math_lib::full_math;
use nerge_math_lib::signed_math;
use nerge_math_lib::tick_math;

// ========================================================================
// Constants
// ========================================================================

/// Q96 constant (2^96)
const Q96: u128 = 79228162514264337593543950336;

// ========================================================================
// Error Codes
// ========================================================================

const ELIQUIDITY_OVERFLOW: u64 = 1;
const ELIQUIDITY_UNDERFLOW: u64 = 2;
const EINVALID_PRICE_RANGE: u64 = 3;
const EZERO_LIQUIDITY: u64 = 4;
const EINSUFFICIENT_AMOUNT: u64 = 5;

const MAX_U128: u128 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;

// ========================================================================
// Structs
// ========================================================================

/// Represents a change in liquidity (can be positive or negative)
public struct LiquidityDelta has copy, drop, store {
    amount: u128,
    is_addition: bool, // true = adding liquidity, false = removing
}

/// Represents token amounts in a position
public struct TokenAmounts has copy, drop, store {
    amount0: u256,
    amount1: u256,
}

// ========================================================================
// Liquidity Delta Operations
// ========================================================================

/// Create a positive liquidity delta (addition)
public fun create_liquidity_addition(amount: u128): LiquidityDelta {
    LiquidityDelta {
        amount,
        is_addition: true,
    }
}

/// Create a negative liquidity delta (removal)
public fun create_liquidity_removal(amount: u128): LiquidityDelta {
    LiquidityDelta {
        amount,
        is_addition: false,
    }
}

/// Apply liquidity delta to current liquidity
public fun apply_liquidity_delta(liquidity: u128, delta: LiquidityDelta): u128 {
    if (delta.is_addition) {
        // Adding liquidity
        let result = (liquidity as u256) + (delta.amount as u256);
        assert!(result <= (MAX_U128 as u256), ELIQUIDITY_OVERFLOW);
        (result as u128)
    } else {
        // Removing liquidity
        assert!(liquidity >= delta.amount, ELIQUIDITY_UNDERFLOW);
        liquidity - delta.amount
    }
}

/// Add liquidity with overflow check
public fun add_liquidity(liquidity: u128, delta: u128): u128 {
    let result = (liquidity as u256) + (delta as u256);
    assert!(result <= (MAX_U128 as u256), ELIQUIDITY_OVERFLOW);
    (result as u128)
}

/// Subtract liquidity with underflow check
public fun sub_liquidity(liquidity: u128, delta: u128): u128 {
    assert!(liquidity >= delta, ELIQUIDITY_UNDERFLOW);
    liquidity - delta
}

// ========================================================================
// Token Amount ↔ Liquidity Conversions
// ========================================================================

/// Calculate amount0 for a given liquidity and price range
/// Formula: amount0 = L * (1/√P_current - 1/√P_upper)
///
/// Used when:
/// - Current price is below the position range (only token0 needed)
/// - Current price is within range (partial token0 needed)
///
/// Rounding: round up to protect the protocol
public fun get_amount0_for_liquidity(
    sqrt_ratio_a_x96: u256,
    sqrt_ratio_b_x96: u256,
    liquidity: u128,
    round_up: bool,
): u256 {
    // Ensure sqrt_ratio_a < sqrt_ratio_b
    let (sqrt_ratio_lower, sqrt_ratio_upper) = if (sqrt_ratio_a_x96 < sqrt_ratio_b_x96) {
        (sqrt_ratio_a_x96, sqrt_ratio_b_x96)
    } else {
        (sqrt_ratio_b_x96, sqrt_ratio_a_x96)
    };

    assert!(sqrt_ratio_lower > 0, EINVALID_PRICE_RANGE);

    // amount0 = liquidity * (sqrt_ratio_upper - sqrt_ratio_lower) / (sqrt_ratio_upper * sqrt_ratio_lower)
    // Rearranged: amount0 = (liquidity << 96) * (sqrt_ratio_upper - sqrt_ratio_lower) / sqrt_ratio_upper / sqrt_ratio_lower

    let numerator1 = (liquidity as u256) << 96;
    let numerator2 = (sqrt_ratio_upper - sqrt_ratio_lower) as u256;

    if (round_up) {
        // Round up: add (denominator - 1) before dividing
        let denominator = full_math::mul_div(
            (sqrt_ratio_upper as u256),
            (sqrt_ratio_lower as u256),
            1,
        );

        full_math::mul_div_rounding_up(
            numerator1,
            numerator2,
            denominator,
        )
    } else {
        // Round down: normal division
        let product = full_math::mul_div(numerator1, numerator2, 1);
        product / full_math::mul_div(
                (sqrt_ratio_upper as u256),
                (sqrt_ratio_lower as u256),
                1
            )
    }
}

/// Calculate amount1 for a given liquidity and price range
/// Formula: amount1 = L * (√P_upper - √P_lower)
///
/// Used when:
/// - Current price is above the position range (only token1 needed)
/// - Current price is within range (partial token1 needed)
///
/// Rounding: round up to protect the protocol
public fun get_amount1_for_liquidity(
    sqrt_ratio_a_x96: u256,
    sqrt_ratio_b_x96: u256,
    liquidity: u128,
    round_up: bool,
): u256 {
    // Ensure sqrt_ratio_a < sqrt_ratio_b
    let (sqrt_ratio_lower, sqrt_ratio_upper) = if (sqrt_ratio_a_x96 < sqrt_ratio_b_x96) {
        (sqrt_ratio_a_x96, sqrt_ratio_b_x96)
    } else {
        (sqrt_ratio_b_x96, sqrt_ratio_a_x96)
    };

    // amount1 = liquidity * (sqrt_ratio_upper - sqrt_ratio_lower) / 2^96
    let diff = (sqrt_ratio_upper - sqrt_ratio_lower) as u256;

    if (round_up) {
        // Round up
        full_math::mul_div_rounding_up(
            (liquidity as u256),
            diff,
            (Q96 as u256),
        )
    } else {
        // Round down
        full_math::mul_div(
            (liquidity as u256),
            diff,
            (Q96 as u256),
        )
    }
}

/// Calculate liquidity from amount0 and price range
/// Formula: L = amount0 / (1/√P_lower - 1/√P_upper)
/// Rearranged: L = amount0 * √P_lower * √P_upper / (√P_upper - √P_lower) / 2^96
public fun get_liquidity_for_amount0(
    sqrt_ratio_a_x96: u256,
    sqrt_ratio_b_x96: u256,
    amount0: u256,
): u128 {
    // Ensure sqrt_ratio_a < sqrt_ratio_b
    let (sqrt_ratio_lower, sqrt_ratio_upper) = if (sqrt_ratio_a_x96 < sqrt_ratio_b_x96) {
        (sqrt_ratio_a_x96, sqrt_ratio_b_x96)
    } else {
        (sqrt_ratio_b_x96, sqrt_ratio_a_x96)
    };

    assert!(sqrt_ratio_lower > 0, EINVALID_PRICE_RANGE);

    let intermediate = full_math::mul_div(
        (sqrt_ratio_lower as u256),
        (sqrt_ratio_upper as u256),
        (Q96 as u256),
    );

    let result = full_math::mul_div(
        amount0,
        intermediate,
        (sqrt_ratio_upper - sqrt_ratio_lower) as u256,
    );

    assert!(result <= (MAX_U128 as u256), ELIQUIDITY_OVERFLOW);
    (result as u128)
}

/// Calculate liquidity from amount1 and price range
/// Formula: L = amount1 / (√P_upper - √P_lower)
public fun get_liquidity_for_amount1(
    sqrt_ratio_a_x96: u256,
    sqrt_ratio_b_x96: u256,
    amount1: u256,
): u128 {
    // Ensure sqrt_ratio_a < sqrt_ratio_b
    let (sqrt_ratio_lower, sqrt_ratio_upper) = if (sqrt_ratio_a_x96 < sqrt_ratio_b_x96) {
        (sqrt_ratio_a_x96, sqrt_ratio_b_x96)
    } else {
        (sqrt_ratio_b_x96, sqrt_ratio_a_x96)
    };

    let result = full_math::mul_div(
        amount1,
        (Q96 as u256),
        (sqrt_ratio_upper - sqrt_ratio_lower) as u256,
    );

    assert!(result <= (MAX_U128 as u256), ELIQUIDITY_OVERFLOW);
    (result as u128)
}

/// Calculate liquidity from amounts (takes the minimum to stay within range)
/// This is the key function for minting new positions
public fun get_liquidity_for_amounts(
    sqrt_ratio_x96: u256,
    sqrt_ratio_a_x96: u256,
    sqrt_ratio_b_x96: u256,
    amount0: u256,
    amount1: u256,
): u128 {
    // Ensure sqrt_ratio_a < sqrt_ratio_b
    let (sqrt_ratio_lower, sqrt_ratio_upper) = if (sqrt_ratio_a_x96 < sqrt_ratio_b_x96) {
        (sqrt_ratio_a_x96, sqrt_ratio_b_x96)
    } else {
        (sqrt_ratio_b_x96, sqrt_ratio_a_x96)
    };

    if (sqrt_ratio_x96 <= sqrt_ratio_lower) {
        // Current price is below range: only token0 is needed
        get_liquidity_for_amount0(sqrt_ratio_lower, sqrt_ratio_upper, amount0)
    } else if (sqrt_ratio_x96 < sqrt_ratio_upper) {
        // Current price is within range: need both tokens
        let liquidity0 = get_liquidity_for_amount0(
            sqrt_ratio_x96,
            sqrt_ratio_upper,
            amount0,
        );
        let liquidity1 = get_liquidity_for_amount1(
            sqrt_ratio_lower,
            sqrt_ratio_x96,
            amount1,
        );

        // Take minimum to ensure both amounts are sufficient
        if (liquidity0 < liquidity1) {
            liquidity0
        } else {
            liquidity1
        }
    } else {
        // Current price is above range: only token1 is needed
        get_liquidity_for_amount1(sqrt_ratio_lower, sqrt_ratio_upper, amount1)
    }
}

/// Calculate token amounts needed for a given liquidity
/// Returns (amount0, amount1)
public fun get_amounts_for_liquidity(
    sqrt_ratio_x96: u256,
    sqrt_ratio_a_x96: u256,
    sqrt_ratio_b_x96: u256,
    liquidity: u128,
): TokenAmounts {
    // Ensure sqrt_ratio_a < sqrt_ratio_b
    let (sqrt_ratio_lower, sqrt_ratio_upper) = if (sqrt_ratio_a_x96 < sqrt_ratio_b_x96) {
        (sqrt_ratio_a_x96, sqrt_ratio_b_x96)
    } else {
        (sqrt_ratio_b_x96, sqrt_ratio_a_x96)
    };

    let amount0: u256;
    let amount1: u256;

    if (sqrt_ratio_x96 <= sqrt_ratio_lower) {
        // Current price is below range: only token0
        amount0 =
            get_amount0_for_liquidity(
                sqrt_ratio_lower,
                sqrt_ratio_upper,
                liquidity,
                true, // round up
            );
        amount1 = 0;
    } else if (sqrt_ratio_x96 < sqrt_ratio_upper) {
        // Current price is within range: both tokens
        amount0 =
            get_amount0_for_liquidity(
                sqrt_ratio_x96,
                sqrt_ratio_upper,
                liquidity,
                true, // round up
            );
        amount1 =
            get_amount1_for_liquidity(
                sqrt_ratio_lower,
                sqrt_ratio_x96,
                liquidity,
                true, // round up
            );
    } else {
        // Current price is above range: only token1
        amount0 = 0;
        amount1 =
            get_amount1_for_liquidity(
                sqrt_ratio_lower,
                sqrt_ratio_upper,
                liquidity,
                true, // round up
            );
    };

    TokenAmounts { amount0, amount1 }
}

// ========================================================================
// Position Delta Calculations
// ========================================================================

/// Calculate token amounts delta when adding liquidity
/// Used when minting a new position or increasing liquidity
public fun get_amounts_for_liquidity_delta(
    sqrt_ratio_x96: u256,
    sqrt_ratio_lower_x96: u256,
    sqrt_ratio_upper_x96: u256,
    liquidity_delta: u128,
): (u256, u256) {
    let amounts = get_amounts_for_liquidity(
        sqrt_ratio_x96,
        sqrt_ratio_lower_x96,
        sqrt_ratio_upper_x96,
        signed_math::abs_i128(liquidity_delta),
    );

    // Convert to signed based on whether we're adding or removing liquidity
    let amount0_signed: u256;
    let amount1_signed: u256;

    if (signed_math::is_negative_i128(liquidity_delta)) {
        // Removing liquidity: amounts are negative (outgoing)
        amount0_signed = signed_math::negate_i256((amounts.amount0 as u256));
        amount1_signed = signed_math::negate_i256((amounts.amount1 as u256));
    } else {
        // Adding liquidity: amounts are positive (incoming)
        amount0_signed = (amounts.amount0 as u256);
        amount1_signed = (amounts.amount1 as u256);
    };

    (amount0_signed, amount1_signed)
}

// ========================================================================
// Helper Functions
// ========================================================================

/// Get amount0 from TokenAmounts struct
public fun get_amount0(amounts: &TokenAmounts): u256 {
    amounts.amount0
}

/// Get amount1 from TokenAmounts struct
public fun get_amount1(amounts: &TokenAmounts): u256 {
    amounts.amount1
}

/// Check if liquidity delta is addition
public fun is_addition(delta: &LiquidityDelta): bool {
    delta.is_addition
}

/// Get amount from liquidity delta
public fun get_delta_amount(delta: &LiquidityDelta): u128 {
    delta.amount
}

// ========================================================================
// Tests
// ========================================================================

#[test]
fun test_liquidity_delta_operations() {
    let initial_liquidity: u128 = 1000000;

    // Test addition
    let add_delta = create_liquidity_addition(500000);
    let after_add = apply_liquidity_delta(initial_liquidity, add_delta);
    assert!(after_add == 1500000, 0);

    // Test removal
    let remove_delta = create_liquidity_removal(300000);
    let after_remove = apply_liquidity_delta(after_add, remove_delta);
    assert!(after_remove == 1200000, 1);
}

#[test]
#[expected_failure(abort_code = ELIQUIDITY_UNDERFLOW)]
fun test_liquidity_underflow() {
    let liquidity: u128 = 100;
    let remove_delta = create_liquidity_removal(200);
    apply_liquidity_delta(liquidity, remove_delta);
}

#[test]
fun test_amount0_calculation() {
    // Test at tick 0 (price = 1.0)
    let sqrt_ratio_current = (Q96 as u256);
    let sqrt_ratio_upper = tick_math::get_sqrt_ratio_at_tick(
        signed_math::from_literal_i32(1000),
    );

    let liquidity: u128 = 1000000000000;

    let amount0 = get_amount0_for_liquidity(
        sqrt_ratio_current,
        sqrt_ratio_upper,
        liquidity,
        false,
    );

    // Amount should be positive
    assert!(amount0 > 0, 0);
}

#[test]
fun test_amount1_calculation() {
    let sqrt_ratio_lower = (Q96 as u256);
    let sqrt_ratio_current = tick_math::get_sqrt_ratio_at_tick(
        signed_math::from_literal_i32(1000),
    );

    let liquidity: u128 = 1000000000000;

    let amount1 = get_amount1_for_liquidity(
        sqrt_ratio_lower,
        sqrt_ratio_current,
        liquidity,
        false,
    );

    // Amount should be positive
    assert!(amount1 > 0, 0);
}

#[test]
fun test_liquidity_from_amount0() {
    let sqrt_ratio_lower = (Q96 as u256);
    let sqrt_ratio_upper = tick_math::get_sqrt_ratio_at_tick(
        signed_math::from_literal_i32(1000),
    );

    let amount0: u256 = 1000000;

    let liquidity = get_liquidity_for_amount0(
        sqrt_ratio_lower,
        sqrt_ratio_upper,
        amount0,
    );

    assert!(liquidity > 0, 0);

    // Verify round trip
    let recovered_amount0 = get_amount0_for_liquidity(
        sqrt_ratio_lower,
        sqrt_ratio_upper,
        liquidity,
        false,
    );

    // Should be close (allowing for rounding)
    assert!(recovered_amount0 <= amount0 * 101 / 100, 1);
}

#[test]
fun test_liquidity_from_amount1() {
    let sqrt_ratio_lower = (Q96 as u256);
    let sqrt_ratio_upper = tick_math::get_sqrt_ratio_at_tick(
        signed_math::from_literal_i32(1000),
    );

    let amount1: u256 = 1000000;

    let liquidity = get_liquidity_for_amount1(
        sqrt_ratio_lower,
        sqrt_ratio_upper,
        amount1,
    );

    assert!(liquidity > 0, 0);
}

#[test]
fun test_liquidity_for_amounts_below_range() {
    // Current price below range: only amount0 matters
    let sqrt_ratio_current = (Q96 as u256); // tick 0
    let sqrt_ratio_lower = tick_math::get_sqrt_ratio_at_tick(
        signed_math::from_literal_i32(1000),
    );
    let sqrt_ratio_upper = tick_math::get_sqrt_ratio_at_tick(
        signed_math::from_literal_i32(2000),
    );

    let amount0: u256 = 1000000;
    let amount1: u256 = 500000;

    let liquidity = get_liquidity_for_amounts(
        sqrt_ratio_current,
        sqrt_ratio_lower,
        sqrt_ratio_upper,
        amount0,
        amount1,
    );

    // Should use amount0 only (current price < range)
    assert!(liquidity > 0, 0);

    // Verify amounts
    let amounts = get_amounts_for_liquidity(
        sqrt_ratio_current,
        sqrt_ratio_lower,
        sqrt_ratio_upper,
        liquidity,
    );

    assert!(amounts.amount0 > 0, 1);
    assert!(amounts.amount1 == 0, 2); // No token1 needed below range
}

#[test]
fun test_liquidity_for_amounts_above_range() {
    // Current price above range: only amount1 matters
    let sqrt_ratio_current = tick_math::get_sqrt_ratio_at_tick(
        signed_math::from_literal_i32(3000),
    );
    let sqrt_ratio_lower = tick_math::get_sqrt_ratio_at_tick(
        signed_math::from_literal_i32(1000),
    );
    let sqrt_ratio_upper = tick_math::get_sqrt_ratio_at_tick(
        signed_math::from_literal_i32(2000),
    );

    let amount0: u256 = 1000000;
    let amount1: u256 = 500000;

    let liquidity = get_liquidity_for_amounts(
        sqrt_ratio_current,
        sqrt_ratio_lower,
        sqrt_ratio_upper,
        amount0,
        amount1,
    );

    // Should use amount1 only (current price > range)
    assert!(liquidity > 0, 0);

    // Verify amounts
    let amounts = get_amounts_for_liquidity(
        sqrt_ratio_current,
        sqrt_ratio_lower,
        sqrt_ratio_upper,
        liquidity,
    );

    assert!(amounts.amount0 == 0, 1); // No token0 needed above range
    assert!(amounts.amount1 > 0, 2);
}

#[test]
fun test_liquidity_for_amounts_in_range() {
    // Current price within range: both tokens needed
    let sqrt_ratio_current = tick_math::get_sqrt_ratio_at_tick(
        signed_math::from_literal_i32(1500),
    );
    let sqrt_ratio_lower = tick_math::get_sqrt_ratio_at_tick(
        signed_math::from_literal_i32(1000),
    );
    let sqrt_ratio_upper = tick_math::get_sqrt_ratio_at_tick(
        signed_math::from_literal_i32(2000),
    );

    let amount0: u256 = 1000000;
    let amount1: u256 = 1000000;

    let liquidity = get_liquidity_for_amounts(
        sqrt_ratio_current,
        sqrt_ratio_lower,
        sqrt_ratio_upper,
        amount0,
        amount1,
    );

    assert!(liquidity > 0, 0);

    // Verify both amounts are used
    let amounts = get_amounts_for_liquidity(
        sqrt_ratio_current,
        sqrt_ratio_lower,
        sqrt_ratio_upper,
        liquidity,
    );

    assert!(amounts.amount0 > 0, 1);
    assert!(amounts.amount1 > 0, 2);
}

#[test]
fun test_rounding_up_vs_down() {
    let sqrt_ratio_lower = (Q96 as u256);
    let sqrt_ratio_upper = tick_math::get_sqrt_ratio_at_tick(
        signed_math::from_literal_i32(100),
    );
    let liquidity: u128 = 1000000;

    // Get amount0 with rounding up
    let amount0_up = get_amount0_for_liquidity(
        sqrt_ratio_lower,
        sqrt_ratio_upper,
        liquidity,
        true,
    );

    // Get amount0 with rounding down
    let amount0_down = get_amount0_for_liquidity(
        sqrt_ratio_lower,
        sqrt_ratio_upper,
        liquidity,
        false,
    );

    // Rounding up should give equal or larger amount
    assert!(amount0_up >= amount0_down, 0);
}
