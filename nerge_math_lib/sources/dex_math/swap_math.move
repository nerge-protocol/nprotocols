/// Swap Math for Uniswap v3-style DEX
///
/// Core Concepts:
/// - Swaps happen in discrete "steps" between ticks
/// - Each step consumes liquidity and changes price
/// - Fees are deducted from input amount
///
/// Key Operations:
/// 1. Compute swap step: given amount in/out, liquidity, and price bounds
/// 2. Calculate next sqrt price after consuming amount
/// 3. Calculate amount in/out for a price change
/// 4. Handle fee deduction
///
/// Formula Reference:
/// - Δ(1/√P) = Δamount0 / L  (for token0)
/// - Δ√P = Δamount1 / L      (for token1)
/// - amountIn = amountOut / (1 - fee)
module nerge_math_lib::swap_math;

use nerge_math_lib::full_math;
use nerge_math_lib::signed_math;

// ========================================================================
// Constants
// ========================================================================

/// Q96 constant (2^96)
const Q96: u128 = 79228162514264337593543950336;

/// Maximum fee: 100% (represented as 1e6 = 1000000)
/// Actual max in Uniswap v3 is 1% = 10000
const MAX_FEE: u32 = 1000000;

/// Fee denominator (1e6 for precision)
const FEE_DENOMINATOR: u32 = 1000000;

// ========================================================================
// Error Codes
// ========================================================================

const EINVALID_FEE: u64 = 1;
const EINVALID_PRICE: u64 = 2;
const EINVALID_LIQUIDITY: u64 = 3;
const EINSUFFICIENT_INPUT_AMOUNT: u64 = 4;
const EINSUFFICIENT_LIQUIDITY: u64 = 5;
const EPRICE_LIMIT_EXCEEDED: u64 = 6;
const EOVERFLOW: u64 = 7;

// ========================================================================
// Structs
// ========================================================================

/// Result of computing a single swap step
public struct SwapStepResult has copy, drop {
    sqrt_price_next_x96: u256, // Price after this step
    amount_in: u256, // Amount of input token consumed
    amount_out: u256, // Amount of output token produced
    fee_amount: u256, // Fee charged (in input token)
}

// ========================================================================
// Core Swap Step Computation
// ========================================================================

/// Compute a single swap step
///
/// Given:
/// - Current price (sqrt_price_current)
/// - Target price (sqrt_price_target) - next tick or price limit
/// - Liquidity available in this range
/// - Amount remaining to swap
/// - Fee tier
///
/// Returns:
/// - Next price after consuming amount
/// - Amount in consumed
/// - Amount out produced
/// - Fee charged
///
/// This is the most critical function in the swap logic
public fun compute_swap_step(
    sqrt_price_current_x96: u256,
    sqrt_price_target_x96: u256,
    liquidity: u128,
    amount_remaining: u256,
    fee_pips: u32,
): SwapStepResult {
    // Validate inputs
    assert!(sqrt_price_current_x96 > 0, EINVALID_PRICE);
    assert!(liquidity > 0, EINVALID_LIQUIDITY);
    assert!(fee_pips <= MAX_FEE, EINVALID_FEE);

    // Determine swap direction
    let zero_for_one = sqrt_price_current_x96 >= sqrt_price_target_x96;
    let exact_in = !signed_math::is_negative_i256(amount_remaining);

    let amount_remaining_abs = signed_math::abs_i256(amount_remaining);

    // Calculate maximum amount that can be swapped in this step
    let sqrt_price_next_x96: u256;
    let amount_in: u256;
    let amount_out: u256;
    let fee_amount: u256;

    if (exact_in) {
        // Exact input: we know how much we're putting in
        // Deduct fee from input amount
        let amount_remaining_less_fee = full_math::mul_div(
            amount_remaining_abs,
            (FEE_DENOMINATOR - fee_pips) as u256,
            FEE_DENOMINATOR as u256,
        );

        // Calculate amount in to reach target price
        let amount_in_to_target = if (zero_for_one) {
            get_amount0_delta(
                sqrt_price_target_x96,
                sqrt_price_current_x96,
                liquidity,
                true, // round up
            )
        } else {
            get_amount1_delta(
                sqrt_price_current_x96,
                sqrt_price_target_x96,
                liquidity,
                true, // round up
            )
        };

        // Check if we'll reach the target price or run out of input
        if (amount_remaining_less_fee >= amount_in_to_target) {
            // We'll reach target price
            sqrt_price_next_x96 = sqrt_price_target_x96;
            amount_in = amount_in_to_target;
        } else {
            // We'll run out of input before reaching target
            sqrt_price_next_x96 =
                get_next_sqrt_price_from_input(
                    sqrt_price_current_x96,
                    liquidity,
                    amount_remaining_less_fee,
                    zero_for_one,
                );
            amount_in = amount_remaining_less_fee;
        };

        // Calculate output amount
        amount_out = if (zero_for_one) {
            get_amount1_delta(
                sqrt_price_next_x96,
                sqrt_price_current_x96,
                liquidity,
                false, // round down (favor protocol)
            )
        } else {
            get_amount0_delta(
                sqrt_price_current_x96,
                sqrt_price_next_x96,
                liquidity,
                false, // round down (favor protocol)
            )
        };

        // Calculate fee
        if (sqrt_price_next_x96 == sqrt_price_target_x96) {
            // Used exact amount to reach target
            fee_amount = amount_remaining_abs - amount_in;
        } else {
            // Calculate fee from amount_in
            fee_amount =
                full_math::mul_div_rounding_up(
                    amount_in,
                    fee_pips as u256,
                    (FEE_DENOMINATOR - fee_pips) as u256,
                );
        };
    } else {
        // Exact output: we know how much we want out

        // Calculate amount out to reach target price
        let amount_out_to_target = if (zero_for_one) {
            get_amount1_delta(
                sqrt_price_target_x96,
                sqrt_price_current_x96,
                liquidity,
                false, // round down
            )
        } else {
            get_amount0_delta(
                sqrt_price_current_x96,
                sqrt_price_target_x96,
                liquidity,
                false, // round down
            )
        };

        // Check if we'll reach target or fulfill the exact output
        if (amount_remaining_abs >= amount_out_to_target) {
            // We'll reach target price
            sqrt_price_next_x96 = sqrt_price_target_x96;
            amount_out = amount_out_to_target;
        } else {
            // We'll fulfill exact output before reaching target
            sqrt_price_next_x96 =
                get_next_sqrt_price_from_output(
                    sqrt_price_current_x96,
                    liquidity,
                    amount_remaining_abs,
                    zero_for_one,
                );
            amount_out = amount_remaining_abs;
        };

        // Calculate input amount needed
        amount_in = if (zero_for_one) {
            get_amount0_delta(
                sqrt_price_next_x96,
                sqrt_price_current_x96,
                liquidity,
                true, // round up (favor protocol)
            )
        } else {
            get_amount1_delta(
                sqrt_price_current_x96,
                sqrt_price_next_x96,
                liquidity,
                true, // round up (favor protocol)
            )
        };

        // Calculate fee
        fee_amount =
            full_math::mul_div_rounding_up(
                amount_in,
                fee_pips as u256,
                (FEE_DENOMINATOR - fee_pips) as u256,
            );
    };

    SwapStepResult {
        sqrt_price_next_x96,
        amount_in,
        amount_out,
        fee_amount,
    }
}

// ========================================================================
// Price Calculation Functions
// ========================================================================

/// Calculate next sqrt price from input amount
/// Formula depends on direction:
/// - token0 -> token1: 1/√P_next = 1/√P_current + Δamount0/L
/// - token1 -> token0: √P_next = √P_current + Δamount1/L
public fun get_next_sqrt_price_from_input(
    sqrt_price_x96: u256,
    liquidity: u128,
    amount_in: u256,
    zero_for_one: bool,
): u256 {
    assert!(sqrt_price_x96 > 0, EINVALID_PRICE);
    assert!(liquidity > 0, EINVALID_LIQUIDITY);

    if (zero_for_one) {
        // Swapping token0 for token1 (price decreases)
        get_next_sqrt_price_from_amount0_rounding_up(
            sqrt_price_x96,
            liquidity,
            amount_in,
            true, // add amount (price goes down)
        )
    } else {
        // Swapping token1 for token0 (price increases)
        get_next_sqrt_price_from_amount1_rounding_down(
            sqrt_price_x96,
            liquidity,
            amount_in,
            true, // add amount (price goes up)
        )
    }
}

/// Calculate next sqrt price from output amount
public fun get_next_sqrt_price_from_output(
    sqrt_price_x96: u256,
    liquidity: u128,
    amount_out: u256,
    zero_for_one: bool,
): u256 {
    assert!(sqrt_price_x96 > 0, EINVALID_PRICE);
    assert!(liquidity > 0, EINVALID_LIQUIDITY);

    if (zero_for_one) {
        // Swapping token0 for token1 (outputting token1)
        get_next_sqrt_price_from_amount1_rounding_down(
            sqrt_price_x96,
            liquidity,
            amount_out,
            false, // subtract amount (price goes down)
        )
    } else {
        // Swapping token1 for token0 (outputting token0)
        get_next_sqrt_price_from_amount0_rounding_up(
            sqrt_price_x96,
            liquidity,
            amount_out,
            false, // subtract amount (price goes up)
        )
    }
}

/// Calculate next sqrt price from amount0
/// Formula: 1/√P_next = 1/√P ± Δamount0/L
/// Rearranged: √P_next = √P * L / (L ± Δamount0 * √P)
fun get_next_sqrt_price_from_amount0_rounding_up(
    sqrt_price_x96: u256,
    liquidity: u128,
    amount: u256,
    add: bool,
): u256 {
    if (amount == 0) {
        return sqrt_price_x96
    };

    let numerator1 = (liquidity as u256) << 96;

    if (add) {
        // Adding amount: price decreases
        // numerator1 / (numerator1 / sqrt_price + amount)
        let product = amount * (sqrt_price_x96 as u256);

        if (product / amount == (sqrt_price_x96 as u256)) {
            // No overflow
            let denominator = numerator1 + product;
            if (denominator >= numerator1) {
                return (
                    full_math::mul_div_rounding_up(
                        numerator1,
                        (sqrt_price_x96 as u256),
                        denominator,
                    ) as u256,
                )
            }
        };

        // Overflow case - use alternative formula
        (
            full_math::mul_div_rounding_up(
                numerator1,
                1,
                (numerator1 / (sqrt_price_x96 as u256)) + amount,
            ) as u256,
        )
    } else {
        // Subtracting amount: price increases
        let product = amount * (sqrt_price_x96 as u256);

        assert!(product / amount == (sqrt_price_x96 as u256), EOVERFLOW);
        assert!(numerator1 > product, EINSUFFICIENT_LIQUIDITY);

        let denominator = numerator1 - product;

        (
            full_math::mul_div_rounding_up(
                numerator1,
                (sqrt_price_x96 as u256),
                denominator,
            ) as u256,
        )
    }
}

/// Calculate next sqrt price from amount1
/// Formula: √P_next = √P ± Δamount1/L
fun get_next_sqrt_price_from_amount1_rounding_down(
    sqrt_price_x96: u256,
    liquidity: u128,
    amount: u256,
    add: bool,
): u256 {
    if (add) {
        // Adding amount: price increases
        let max_u128: u128 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
        let quotient = if (amount <= (max_u128 as u256)) {
            // Amount fits in u128, can left shift
            (amount << 96) / (liquidity as u256)
        } else {
            // Amount too large, use mul_div
            full_math::mul_div(amount, (Q96 as u256), (liquidity as u256))
        };

        ((sqrt_price_x96 as u256) + quotient as u256)
    } else {
        // Subtracting amount: price decreases
        let quotient = full_math::mul_div_rounding_up(
            amount,
            (Q96 as u256),
            (liquidity as u256),
        );

        assert!((sqrt_price_x96 as u256) > quotient, EINSUFFICIENT_LIQUIDITY);

        ((sqrt_price_x96 as u256) - quotient as u256)
    }
}

// ========================================================================
// Amount Delta Calculations
// ========================================================================

/// Get amount0 delta between two sqrt prices
/// Formula: Δamount0 = L * (1/√P_a - 1/√P_b)
///        = L * (√P_b - √P_a) / (√P_a * √P_b)
public fun get_amount0_delta(
    sqrt_ratio_a_x96: u256,
    sqrt_ratio_b_x96: u256,
    liquidity: u128,
    round_up: bool,
): u256 {
    // Ensure a < b for consistent calculation
    let (sqrt_ratio_lower, sqrt_ratio_upper) = if (sqrt_ratio_a_x96 < sqrt_ratio_b_x96) {
        (sqrt_ratio_a_x96, sqrt_ratio_b_x96)
    } else {
        (sqrt_ratio_b_x96, sqrt_ratio_a_x96)
    };

    let numerator1 = (liquidity as u256) << 96;
    let numerator2 = (sqrt_ratio_upper - sqrt_ratio_lower) as u256;

    assert!(sqrt_ratio_lower > 0, EINVALID_PRICE);

    if (round_up) {
        full_math::mul_div_rounding_up(
            full_math::mul_div_rounding_up(
                numerator1,
                numerator2,
                (sqrt_ratio_upper as u256),
            ),
            1,
            (sqrt_ratio_lower as u256),
        )
    } else {
        full_math::mul_div(
                numerator1,
                numerator2,
                (sqrt_ratio_upper as u256)
            ) / (sqrt_ratio_lower as u256)
    }
}

/// Get amount1 delta between two sqrt prices
/// Formula: Δamount1 = L * (√P_b - √P_a)
public fun get_amount1_delta(
    sqrt_ratio_a_x96: u256,
    sqrt_ratio_b_x96: u256,
    liquidity: u128,
    round_up: bool,
): u256 {
    // Ensure a < b for consistent calculation
    let (sqrt_ratio_lower, sqrt_ratio_upper) = if (sqrt_ratio_a_x96 < sqrt_ratio_b_x96) {
        (sqrt_ratio_a_x96, sqrt_ratio_b_x96)
    } else {
        (sqrt_ratio_b_x96, sqrt_ratio_a_x96)
    };

    let diff = (sqrt_ratio_upper - sqrt_ratio_lower) as u256;

    if (round_up) {
        full_math::mul_div_rounding_up(
            (liquidity as u256),
            diff,
            (Q96 as u256),
        )
    } else {
        full_math::mul_div(
            (liquidity as u256),
            diff,
            (Q96 as u256),
        )
    }
}

// ========================================================================
// Accessor Functions
// ========================================================================

public fun get_sqrt_price_next(result: &SwapStepResult): u256 {
    result.sqrt_price_next_x96
}

public fun get_amount_in(result: &SwapStepResult): u256 {
    result.amount_in
}

public fun get_amount_out(result: &SwapStepResult): u256 {
    result.amount_out
}

public fun get_fee_amount(result: &SwapStepResult): u256 {
    result.fee_amount
}

// ========================================================================
// Tests
// ========================================================================

#[test]
fun test_swap_step_exact_input_zero_for_one() {
    // Swap token0 for token1 (exact input)
    let sqrt_price_current: u256 = 79228162514264337593543950336; // √1.0
    let sqrt_price_target: u256 = 79228162514264337593543950336 / 2; // √0.25
    let liquidity: u128 = 1000000000000;
    let amount_in: u256 = 1000000; // Exact input (positive)
    let fee_pips: u32 = 3000; // 0.3%

    let result = compute_swap_step(
        sqrt_price_current,
        sqrt_price_target,
        liquidity,
        amount_in,
        fee_pips,
    );

    // Price should decrease (moving toward target)
    assert!(result.sqrt_price_next_x96 < sqrt_price_current, 0);

    // Should consume input
    assert!(result.amount_in > 0, 1);
    assert!(result.amount_in <= (amount_in as u256), 2);

    // Should produce output
    assert!(result.amount_out > 0, 3);

    // Should charge fee
    assert!(result.fee_amount > 0, 4);
}

#[test]
fun test_swap_step_exact_input_one_for_zero() {
    // Swap token1 for token0 (exact input)
    let sqrt_price_current: u256 = 79228162514264337593543950336; // √1.0
    let sqrt_price_target: u256 = 79228162514264337593543950336 * 2; // √4.0
    let liquidity: u128 = 1000000000000;
    let amount_in: u256 = 1000000;
    let fee_pips: u32 = 3000;

    let result = compute_swap_step(
        sqrt_price_current,
        sqrt_price_target,
        liquidity,
        amount_in,
        fee_pips,
    );

    // Price should increase
    assert!(result.sqrt_price_next_x96 > sqrt_price_current, 0);
    assert!(result.amount_in > 0, 1);
    assert!(result.amount_out > 0, 2);
    assert!(result.fee_amount > 0, 3);
}

#[test]
fun test_swap_step_exact_output() {
    // Exact output (negative amount_remaining)
    let sqrt_price_current: u256 = 79228162514264337593543950336;
    let sqrt_price_target: u256 = 79228162514264337593543950336 / 2;
    let liquidity: u128 = 1000000000000;
    let amount_out: u256 = signed_math::negate_i256(500000); // Exact output (negative)
    let fee_pips: u32 = 3000;

    let result = compute_swap_step(
        sqrt_price_current,
        sqrt_price_target,
        liquidity,
        amount_out,
        fee_pips,
    );

    // Should produce the requested output (or less if hitting target)
    assert!(result.amount_out > 0, 0);
    assert!(result.amount_in > 0, 1);
    assert!(result.fee_amount > 0, 2);
}

#[test]
fun test_get_next_sqrt_price_from_input_token0() {
    let sqrt_price: u256 = 79228162514264337593543950336; // √1.0
    let liquidity: u128 = 1000000000000;
    let amount_in: u256 = 1000000;

    let next_price = get_next_sqrt_price_from_input(
        sqrt_price,
        liquidity,
        amount_in,
        true, // zero for one
    );

    // Price should decrease when swapping token0 for token1
    assert!(next_price < sqrt_price, 0);
}

#[test]
fun test_get_next_sqrt_price_from_input_token1() {
    let sqrt_price: u256 = 79228162514264337593543950336;
    let liquidity: u128 = 1000000000000;
    let amount_in: u256 = 1000000;

    let next_price = get_next_sqrt_price_from_input(
        sqrt_price,
        liquidity,
        amount_in,
        false, // one for zero
    );

    // Price should increase when swapping token1 for token0
    assert!(next_price > sqrt_price, 0);
}

#[test]
fun test_amount0_delta() {
    let sqrt_price_lower: u256 = 79228162514264337593543950336; // √1.0
    let sqrt_price_upper: u256 = 79228162514264337593543950336 * 2; // √4.0 (approx)
    let liquidity: u128 = 1000000000000;

    let amount0_down = get_amount0_delta(
        sqrt_price_lower,
        sqrt_price_upper,
        liquidity,
        false,
    );

    let amount0_up = get_amount0_delta(
        sqrt_price_lower,
        sqrt_price_upper,
        liquidity,
        true,
    );

    // Both should be positive
    assert!(amount0_down > 0, 0);
    assert!(amount0_up > 0, 1);

    // Round up should be >= round down
    assert!(amount0_up >= amount0_down, 2);
}

#[test]
fun test_amount1_delta() {
    let sqrt_price_lower: u256 = 79228162514264337593543950336;
    let sqrt_price_upper: u256 = 79228162514264337593543950336 * 2;
    let liquidity: u128 = 1000000000000;

    let amount1_down = get_amount1_delta(
        sqrt_price_lower,
        sqrt_price_upper,
        liquidity,
        false,
    );

    let amount1_up = get_amount1_delta(
        sqrt_price_lower,
        sqrt_price_upper,
        liquidity,
        true,
    );

    assert!(amount1_down > 0, 0);
    assert!(amount1_up > 0, 1);
    assert!(amount1_up >= amount1_down, 2);
}

#[test]
fun test_fee_calculation() {
    // 0.3% fee = 3000 pips
    let sqrt_price_current: u256 = 79228162514264337593543950336;
    let sqrt_price_target: u256 = 79228162514264337593543950336 / 2;
    let liquidity: u128 = 1000000000000;
    let amount_in: u256 = 1000000;
    let fee_pips: u32 = 3000;

    let result = compute_swap_step(
        sqrt_price_current,
        sqrt_price_target,
        liquidity,
        amount_in,
        fee_pips,
    );

    // Fee should be approximately 0.3% of amount_in
    let expected_fee_approx = (result.amount_in * 3) / 1000;
    let fee_diff = if (result.fee_amount > expected_fee_approx) {
        result.fee_amount - expected_fee_approx
    } else {
        expected_fee_approx - result.fee_amount
    };

    // Allow 10% tolerance due to rounding
    assert!(fee_diff < expected_fee_approx / 10, 0);
}

#[test]
fun test_reaches_target_price() {
    // Large amount should reach target price
    let sqrt_price_current: u256 = 79228162514264337593543950336;
    let sqrt_price_target: u256 = 79228162514264337593543950336 / 2;
    let liquidity: u128 = 1000000;
    let large_amount: u256 = 999999999999999; // Very large
    let fee_pips: u32 = 3000;

    let result = compute_swap_step(
        sqrt_price_current,
        sqrt_price_target,
        liquidity,
        large_amount,
        fee_pips,
    );

    // Should reach exactly the target price
    assert!(result.sqrt_price_next_x96 == sqrt_price_target, 0);
}

#[test]
fun test_small_swap() {
    // Very small swap amount
    let sqrt_price_current: u256 = 79228162514264337593543950336;
    let sqrt_price_target: u256 = 79228162514264337593543950336 / 2;
    let liquidity: u128 = 1000000000000;
    let small_amount: u256 = 100; // Very small
    let fee_pips: u32 = 3000;

    let result = compute_swap_step(
        sqrt_price_current,
        sqrt_price_target,
        liquidity,
        small_amount,
        fee_pips,
    );

    // Should not reach target with small amount
    assert!(result.sqrt_price_next_x96 != sqrt_price_target, 0);
    assert!(result.sqrt_price_next_x96 < sqrt_price_current, 1);

    // But should still produce some output
    assert!(result.amount_out > 0 || small_amount < 10, 2);
}

#[test]
#[expected_failure(abort_code = EINVALID_FEE)]
fun test_invalid_fee() {
    let sqrt_price_current: u256 = 79228162514264337593543950336;
    let sqrt_price_target: u256 = 79228162514264337593543950336 / 2;
    let liquidity: u128 = 1000000000000;
    let amount_in: u256 = 1000000;
    let invalid_fee: u32 = 1000001; // > 100%

    compute_swap_step(
        sqrt_price_current,
        sqrt_price_target,
        liquidity,
        amount_in,
        invalid_fee,
    );
}

#[test]
#[expected_failure(abort_code = EINVALID_LIQUIDITY)]
fun test_zero_liquidity() {
    let sqrt_price_current: u256 = 79228162514264337593543950336;
    let sqrt_price_target: u256 = 79228162514264337593543950336 / 2;
    let liquidity: u128 = 0; // Zero liquidity!
    let amount_in: u256 = 1000000;
    let fee_pips: u32 = 3000;

    compute_swap_step(
        sqrt_price_current,
        sqrt_price_target,
        liquidity,
        amount_in,
        fee_pips,
    );
}
