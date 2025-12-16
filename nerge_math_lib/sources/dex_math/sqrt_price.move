/// Square Root Price Math for Uniswap v3-style DEX
///
/// Core Concepts:
/// - Uniswap v3 stores prices as sqrtPriceX96 = sqrt(price) × 2^96
/// - This simplifies the math for liquidity calculations
/// - sqrt representation makes token amount formulas linear in L
///
/// Why Square Root?
/// Traditional: amount0 = L × (1/√P_b - 1/√P_a)
/// With sqrt:   amount0 = L × (√P_b - √P_a) / (√P_a × √P_b)
///
/// This module provides:
/// - Conversion between price and sqrtPrice
/// - Square root calculation with high precision
/// - Price arithmetic operations
/// - Validation and bounds checking
module nerge_math_lib::sqrt_price;

use nerge_math_lib::fixed_point;
use nerge_math_lib::full_math;

// ========================================================================
// Constants
// ========================================================================

/// Q96 constant (2^96)
const Q96: u128 = 79228162514264337593543950336;

/// Minimum sqrt price (corresponds to MIN_TICK = -887272)
/// At this price: price ≈ 4.2e-37
const MIN_SQRT_PRICE_X96: u256 = 4295128739;

/// Maximum sqrt price (corresponds to MAX_TICK = 887272)
/// At this price: price ≈ 2.4e36
const MAX_SQRT_PRICE_X96: u256 = 1461446703485210103287273052203988822378723970342;

/// Maximum u160 value
const MAX_U160: u256 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;

// ========================================================================
// Error Codes
// ========================================================================

const ESQRT_PRICE_OUT_OF_BOUNDS: u64 = 1;
const EINVALID_PRICE: u64 = 2;
const EOVERFLOW: u64 = 3;
const EINVALID_SQRT_PRICE: u64 = 4;
const ESQRT_OF_NEGATIVE: u64 = 5;

// ========================================================================
// Type-Safe Wrapper
// ========================================================================

/// Square root price in X96 format
/// Represents: sqrt(price) × 2^96
public struct SqrtPriceX96 has copy, drop, store {
    value: u256,
}

// ========================================================================
// Creation and Conversion
// ========================================================================

/// Create SqrtPriceX96 from raw u160 value
public fun from_raw(value: u256): SqrtPriceX96 {
    assert!(value >= MIN_SQRT_PRICE_X96 && value <= MAX_SQRT_PRICE_X96, ESQRT_PRICE_OUT_OF_BOUNDS);
    SqrtPriceX96 { value }
}

/// Create SqrtPriceX96 without bounds checking (unsafe, use with caution)
public fun from_raw_unchecked(value: u256): SqrtPriceX96 {
    SqrtPriceX96 { value }
}

/// Get raw u160 value
public fun to_raw(sqrt_price: SqrtPriceX96): u256 {
    sqrt_price.value
}

/// Create SqrtPriceX96 from integer price
/// Example: from_price(1) creates sqrtPrice for price = 1.0
public fun from_price(price: u256): SqrtPriceX96 {
    assert!(price > 0, EINVALID_PRICE);

    // sqrt(price) × 2^96
    // = sqrt(price × 2^192)
    let price_shifted = price << 192;
    let sqrt_val = sqrt_u256(price_shifted);

    assert!(sqrt_val <= (MAX_U160 as u256), EOVERFLOW);

    SqrtPriceX96 {
        value: (sqrt_val as u256),
    }
}

/// Convert SqrtPriceX96 back to price (loses precision)
/// Returns: price × 2^96 (in Q96 format)
public fun to_price_x96(sqrt_price: SqrtPriceX96): u256 {
    // price = (sqrtPrice / 2^96)^2
    // = sqrtPrice^2 / 2^192
    // Rearranged: price × 2^96 = sqrtPrice^2 / 2^96

    let squared = (sqrt_price.value as u256) * (sqrt_price.value as u256);
    squared >> 96
}

/// Convert SqrtPriceX96 to actual price (as Q64.96 fixed-point)
public fun to_price_q64_96(sqrt_price: SqrtPriceX96): fixed_point::Q64_96 {
    let price_x96 = to_price_x96(sqrt_price);
    fixed_point::from_raw_q64_96((price_x96 as u256))
}

/// Create SqrtPriceX96 from ratio of two token amounts
/// ratio = amount1 / amount0
/// sqrtPrice = sqrt(ratio) × 2^96
public fun from_ratio(amount0: u256, amount1: u256): SqrtPriceX96 {
    assert!(amount0 > 0 && amount1 > 0, EINVALID_PRICE);

    // sqrt(amount1 / amount0) × 2^96
    // = sqrt(amount1 × 2^192 / amount0)

    let numerator = amount1 << 192;
    let ratio_shifted = numerator / amount0;
    let sqrt_val = sqrt_u256(ratio_shifted);

    assert!(sqrt_val <= (MAX_U160 as u256), EOVERFLOW);
    assert!(sqrt_val >= (MIN_SQRT_PRICE_X96 as u256), ESQRT_PRICE_OUT_OF_BOUNDS);

    SqrtPriceX96 {
        value: (sqrt_val as u256),
    }
}

// ========================================================================
// Square Root Calculation (Newton-Raphson)
// ========================================================================

/// Calculate square root of u256 using Newton-Raphson method
/// This is a high-precision implementation needed for price calculations
public fun sqrt_u256(x: u256): u256 {
    if (x == 0) {
        return 0
    };

    // Newton-Raphson: x_{n+1} = (x_n + N/x_n) / 2
    // We need about 8 iterations for 256-bit precision

    // Start with a good initial guess using bit manipulation
    // Find the most significant bit position
    let mut z = x;
    let mut y = (x + 1) / 2;

    // Iterate until convergence
    while (y < z) {
        z = y;
        y = (x / y + y) / 2;
    };

    z
}

/// Calculate square root with better initial guess (optimized version)
public fun sqrt_u256_optimized(x: u256): u256 {
    if (x == 0) {
        return 0
    };

    if (x <= 3) {
        return 1
    };

    // Find position of most significant bit for better initial guess
    let mut z = x;
    let mut n: u8 = 0;

    if (z >= 0x100000000000000000000000000000000) { z = z >> 128; n = n + 128; };
    if (z >= 0x10000000000000000) { z = z >> 64; n = n + 64; };
    if (z >= 0x100000000) { z = z >> 32; n = n + 32; };
    if (z >= 0x10000) { z = z >> 16; n = n + 16; };
    if (z >= 0x100) { z = z >> 8; n = n + 8; };
    if (z >= 0x10) { z = z >> 4; n = n + 4; };
    if (z >= 0x4) { z = z >> 2; n = n + 2; };
    if (z >= 0x2) { n = n + 1; };

    // Initial guess based on bit position
    z = 1u256 << ((n + 1) / 2);

    // Newton-Raphson iterations
    let mut result = (x / z + z) / 2;
    result = (x / result + result) / 2;
    result = (x / result + result) / 2;
    result = (x / result + result) / 2;
    result = (x / result + result) / 2;
    result = (x / result + result) / 2;
    result = (x / result + result) / 2;

    // Return minimum of result and x/result (handles rounding)
    let check = x / result;
    if (check < result) {
        check
    } else {
        result
    }
}

// ========================================================================
// Arithmetic Operations on SqrtPrice
// ========================================================================

/// Multiply sqrtPrice by a scalar (useful for price adjustments)
/// Returns: sqrtPrice × scalar / denominator
public fun mul_ratio(sqrt_price: SqrtPriceX96, numerator: u256, denominator: u256): SqrtPriceX96 {
    let result = full_math::mul_div(
        (sqrt_price.value as u256),
        numerator,
        denominator,
    );

    assert!(result <= (MAX_U160 as u256), EOVERFLOW);
    assert!(result >= (MIN_SQRT_PRICE_X96 as u256), ESQRT_PRICE_OUT_OF_BOUNDS);

    SqrtPriceX96 {
        value: (result as u256),
    }
}

/// Add a delta to sqrtPrice (used in swap calculations)
public fun add_delta(sqrt_price: SqrtPriceX96, delta: u256): SqrtPriceX96 {
    let result = (sqrt_price.value as u256) + (delta as u256);
    assert!(result <= (MAX_U160 as u256), EOVERFLOW);

    SqrtPriceX96 {
        value: (result as u256),
    }
}

/// Subtract a delta from sqrtPrice
public fun sub_delta(sqrt_price: SqrtPriceX96, delta: u256): SqrtPriceX96 {
    assert!(sqrt_price.value >= delta, EINVALID_SQRT_PRICE);

    SqrtPriceX96 {
        value: sqrt_price.value - delta,
    }
}

// ========================================================================
// Comparison Operations
// ========================================================================

/// Check if sqrt_price_a < sqrt_price_b
public fun less_than(a: SqrtPriceX96, b: SqrtPriceX96): bool {
    a.value < b.value
}

/// Check if sqrt_price_a <= sqrt_price_b
public fun less_than_or_equal(a: SqrtPriceX96, b: SqrtPriceX96): bool {
    a.value <= b.value
}

/// Check if sqrt_price_a > sqrt_price_b
public fun greater_than(a: SqrtPriceX96, b: SqrtPriceX96): bool {
    a.value > b.value
}

/// Check if sqrt_price_a >= sqrt_price_b
public fun greater_than_or_equal(a: SqrtPriceX96, b: SqrtPriceX96): bool {
    a.value >= b.value
}

/// Check if sqrt_price_a == sqrt_price_b
public fun equal(a: SqrtPriceX96, b: SqrtPriceX96): bool {
    a.value == b.value
}

// ========================================================================
// Validation and Bounds
// ========================================================================

/// Check if sqrt price is within valid bounds
public fun is_valid(sqrt_price: SqrtPriceX96): bool {
    sqrt_price.value >= MIN_SQRT_PRICE_X96 && 
        sqrt_price.value <= MAX_SQRT_PRICE_X96
}

/// Get minimum sqrt price
public fun min_sqrt_price(): SqrtPriceX96 {
    SqrtPriceX96 { value: MIN_SQRT_PRICE_X96 }
}

/// Get maximum sqrt price
public fun max_sqrt_price(): SqrtPriceX96 {
    SqrtPriceX96 { value: MAX_SQRT_PRICE_X96 }
}

/// Get sqrt price at 1.0 (tick 0)
public fun one(): SqrtPriceX96 {
    SqrtPriceX96 { value: (Q96 as u256) }
}

/// Clamp sqrt price to valid range
public fun clamp(sqrt_price: SqrtPriceX96): SqrtPriceX96 {
    if (sqrt_price.value < MIN_SQRT_PRICE_X96) {
        SqrtPriceX96 { value: MIN_SQRT_PRICE_X96 }
    } else if (sqrt_price.value > MAX_SQRT_PRICE_X96) {
        SqrtPriceX96 { value: MAX_SQRT_PRICE_X96 }
    } else {
        sqrt_price
    }
}

// ========================================================================
// Helper Functions
// ========================================================================

/// Encode two sqrtPrice values into a single u256 (for storage optimization)
/// Note: Each value must fit in 128 bits (not the full u160 range)
public fun encode_two(a: SqrtPriceX96, b: SqrtPriceX96): u256 {
    // Pack two 128-bit values into a single u256
    // a goes in upper 128 bits, b in lower 128 bits
    assert!(a.value < (1u256 << 128), EOVERFLOW);
    assert!(b.value < (1u256 << 128), EOVERFLOW);

    (a.value << 128) | b.value
}

/// Decode two sqrtPrice values from a single u256
public fun decode_two(encoded: u256): (SqrtPriceX96, SqrtPriceX96) {
    let a_value = encoded >> 128;
    let b_value = encoded & ((1u256 << 128) - 1);

    (SqrtPriceX96 { value: a_value }, SqrtPriceX96 { value: b_value })
}

/// Calculate percentage difference between two sqrt prices
/// Returns: (abs(a - b) / a) × 10000 (in basis points)
public fun percentage_diff_bps(a: SqrtPriceX96, b: SqrtPriceX96): u256 {
    let diff = if (a.value > b.value) {
        (a.value - b.value) as u256
    } else {
        (b.value - a.value) as u256
    };

    // diff / a × 10000
    full_math::mul_div(diff, 10000, (a.value as u256))
}

// ========================================================================
// Advanced Price Calculations
// ========================================================================

/// Calculate geometric mean of two sqrt prices
/// Returns: sqrt(a × b)
public fun geometric_mean(a: SqrtPriceX96, b: SqrtPriceX96): SqrtPriceX96 {
    let product = full_math::mul_div(
        (a.value as u256),
        (b.value as u256),
        (Q96 as u256),
    );

    let sqrt_val = sqrt_u256_optimized(product * (Q96 as u256));

    assert!(sqrt_val <= (MAX_U160 as u256), EOVERFLOW);

    SqrtPriceX96 {
        value: (sqrt_val as u256),
    }
}

/// Calculate arithmetic mean of two sqrt prices
/// Returns: (a + b) / 2
public fun arithmetic_mean(a: SqrtPriceX96, b: SqrtPriceX96): SqrtPriceX96 {
    let sum = (a.value as u256) + (b.value as u256);
    let avg = sum / 2;

    assert!(avg <= (MAX_U160 as u256), EOVERFLOW);

    SqrtPriceX96 {
        value: (avg as u256),
    }
}

/// Interpolate between two sqrt prices
/// t = 0 returns a, t = 1000000 returns b
/// Linear interpolation: a + (b - a) × (t / 1000000)
public fun interpolate(
    a: SqrtPriceX96,
    b: SqrtPriceX96,
    t: u32, // 0 to 1000000 (0% to 100%)
): SqrtPriceX96 {
    assert!(t <= 1000000, 0);

    if (t == 0) {
        return a
    };
    if (t == 1000000) {
        return b
    };

    let diff = if (b.value > a.value) {
        (b.value - a.value) as u256
    } else {
        (a.value - b.value) as u256
    };

    let delta = full_math::mul_div(
        diff,
        (t as u256),
        1000000,
    );

    let result = if (b.value > a.value) {
        (a.value as u256) + delta
    } else {
        (a.value as u256) - delta
    };

    assert!(result <= (MAX_U160 as u256), EOVERFLOW);

    SqrtPriceX96 {
        value: (result as u256),
    }
}

// ========================================================================
// Tests
// ========================================================================

#[test]
fun test_from_price() {
    // Price = 1.0 should give sqrtPrice = 1.0 × 2^96 = 2^96
    let sqrt_price = from_price(1);
    assert!(sqrt_price.value == (Q96 as u256), 0);
}

#[test]
fun test_to_price() {
    // sqrtPrice = 2^96 should give price × 2^96 = 2^96
    let sqrt_price = SqrtPriceX96 { value: (Q96 as u256) };
    let price_x96 = to_price_x96(sqrt_price);
    assert!(price_x96 == (Q96 as u256), 0);
}

#[test]
fun test_from_ratio() {
    // ratio = 1000/1000 = 1.0
    let sqrt_price = from_ratio(1000, 1000);
    assert!(sqrt_price.value == (Q96 as u256), 0);

    // ratio = 4000/1000 = 4.0, sqrtPrice should be 2.0 × 2^96
    let sqrt_price_4 = from_ratio(1000, 4000);
    assert!(sqrt_price_4.value > sqrt_price.value, 1);
}

#[test]
fun test_sqrt_u256_simple() {
    assert!(sqrt_u256(0) == 0, 0);
    assert!(sqrt_u256(1) == 1, 1);
    assert!(sqrt_u256(4) == 2, 2);
    assert!(sqrt_u256(9) == 3, 3);
    assert!(sqrt_u256(16) == 4, 4);
    assert!(sqrt_u256(100) == 10, 5);
}

#[test]
fun test_sqrt_u256_large() {
    // Test with large numbers
    let large = 1000000000000000000u256;
    let sqrt_large = sqrt_u256(large);

    // Verify: sqrt^2 should be close to original
    let squared = sqrt_large * sqrt_large;
    assert!(squared <= large, 0);
    assert!(squared >= large - (sqrt_large * 2), 1); // Within tolerance
}

#[test]
fun test_sqrt_optimized_vs_basic() {
    let test_values = vector[0, 1, 4, 9, 16, 100, 10000, 1000000];

    let mut i = 0;
    while (i < vector::length(&test_values)) {
        let val = *vector::borrow(&test_values, i);
        let result1 = sqrt_u256(val);
        let result2 = sqrt_u256_optimized(val);

        // Results should be identical or within 1
        let diff = if (result1 > result2) {
            result1 - result2
        } else {
            result2 - result1
        };
        assert!(diff <= 1, i);

        i = i + 1;
    };
}

#[test]
fun test_comparison_operations() {
    let one = one();
    let two = from_price(4); // sqrt(4) = 2

    assert!(less_than(one, two), 0);
    assert!(greater_than(two, one), 1);
    assert!(equal(one, one), 2);
    assert!(less_than_or_equal(one, one), 3);
}

#[test]
fun test_arithmetic_operations() {
    let one = one();
    let delta: u256 = 1000;

    let increased = add_delta(one, delta);
    assert!(increased.value == one.value + delta, 0);

    let decreased = sub_delta(increased, delta);
    assert!(decreased.value == one.value, 1);
}

#[test]
fun test_mul_ratio() {
    let one = one();

    // Multiply by 2/1 (double)
    let doubled = mul_ratio(one, 2, 1);
    assert!(doubled.value == one.value * 2, 0);

    // Multiply by 1/2 (halve)
    let halved = mul_ratio(one, 1, 2);
    assert!(halved.value == one.value / 2, 1);
}

#[test]
fun test_min_max_sqrt_price() {
    let min = min_sqrt_price();
    let max = max_sqrt_price();

    assert!(min.value == MIN_SQRT_PRICE_X96, 0);
    assert!(max.value == MAX_SQRT_PRICE_X96, 1);
    assert!(less_than(min, max), 2);
}

#[test]
fun test_is_valid() {
    let valid = one();
    assert!(is_valid(valid), 0);

    let min = min_sqrt_price();
    assert!(is_valid(min), 1);

    let max = max_sqrt_price();
    assert!(is_valid(max), 2);
}

#[test]
fun test_clamp() {
    let one = one();
    let clamped = clamp(one);
    assert!(equal(one, clamped), 0);
}

#[test]
fun test_encode_decode() {
    let a = one();
    let b = from_price(4);

    let encoded = encode_two(a, b);
    let (decoded_a, decoded_b) = decode_two(encoded);

    assert!(equal(a, decoded_a), 0);
    assert!(equal(b, decoded_b), 1);
}

#[test]
fun test_percentage_diff() {
    let one = one();
    let two = from_price(4); // sqrt(4) = 2.0 × 2^96

    let diff_bps = percentage_diff_bps(one, two);

    // Difference should be approximately 100% = 10000 bps
    // Since one = 2^96, two = 2 × 2^96
    // diff = 2^96 / 2^96 × 10000 = 10000
    assert!(diff_bps >= 9900 && diff_bps <= 10100, 0);
}

#[test]
fun test_geometric_mean() {
    // geometric mean of 1 and 4 should be 2
    let one = from_price(1);
    let four = from_price(16); // sqrt(16) = 4 in sqrtPrice

    let mean = geometric_mean(one, four);

    // sqrt(1 × 4) = sqrt(4) = 2
    // This should be between one and four
    assert!(greater_than(mean, one), 0);
    assert!(less_than(mean, four), 1);
}

#[test]
fun test_arithmetic_mean() {
    let one = from_price(1);
    let three = from_price(9); // sqrt(9) = 3

    let mean = arithmetic_mean(one, three);

    // (1 + 3) / 2 = 2 in sqrtPrice space
    assert!(greater_than(mean, one), 0);
    assert!(less_than(mean, three), 1);
}

#[test]
fun test_interpolate() {
    let one = from_price(1);
    let two = from_price(4);

    // t = 0 should return a
    let at_zero = interpolate(one, two, 0);
    assert!(equal(at_zero, one), 0);

    // t = 1000000 should return b
    let at_one = interpolate(one, two, 1000000);
    assert!(equal(at_one, two), 1);

    // t = 500000 should be halfway
    let halfway = interpolate(one, two, 500000);
    assert!(greater_than(halfway, one), 2);
    assert!(less_than(halfway, two), 3);
}

#[test]
fun test_round_trip_price_conversion() {
    // Start with a price, convert to sqrtPrice, convert back
    let original_price: u256 = 1234567;
    let sqrt_price = from_price(original_price);
    let recovered_price_x96 = to_price_x96(sqrt_price);
    let recovered_price = recovered_price_x96 / (Q96 as u256);

    // Should be close to original (allowing for rounding)
    let diff = if (recovered_price > original_price) {
        recovered_price - original_price
    } else {
        original_price - recovered_price
    };

    // Allow 1% error due to rounding
    assert!(diff < original_price / 100, 0);
}

#[test]
#[expected_failure(abort_code = ESQRT_PRICE_OUT_OF_BOUNDS)]
fun test_sqrt_price_too_small() {
    from_raw(MIN_SQRT_PRICE_X96 - 1);
}

#[test]
#[expected_failure(abort_code = ESQRT_PRICE_OUT_OF_BOUNDS)]
fun test_sqrt_price_too_large() {
    from_raw(MAX_SQRT_PRICE_X96 + 1);
}

#[test]
#[expected_failure(abort_code = EINVALID_PRICE)]
fun test_from_price_zero() {
    from_price(0);
}

#[test]
#[expected_failure(abort_code = EINVALID_PRICE)]
fun test_from_ratio_zero_amount0() {
    from_ratio(0, 1000);
}

#[test]
#[expected_failure(abort_code = EINVALID_PRICE)]
fun test_from_ratio_zero_amount1() {
    from_ratio(1000, 0);
}
