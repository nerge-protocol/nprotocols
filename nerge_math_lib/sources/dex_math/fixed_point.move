/// Fixed-Point Arithmetic for Uniswap v3-style DEX
///
/// Implements various fixed-point number formats for precise calculations
/// without floating-point arithmetic.
///
/// Supported Formats:
/// - Q64.64:  64-bit integer, 64-bit fractional (total 128 bits)
/// - Q64.96:  64-bit integer, 96-bit fractional (total 160 bits) - Uniswap v3's sqrtPriceX96
/// - Q128.128: 128-bit integer, 128-bit fractional (total 256 bits)
///
/// Key Concept:
/// A fixed-point number stores: value = raw_value / 2^fractional_bits
///
/// Example (Q64.64):
///   To store 1.5:
///   raw_value = 1.5 × 2^64 = 27670116110564327424
///   To retrieve: 27670116110564327424 / 2^64 = 1.5
module nerge_math_lib::fixed_point;

use nerge_math_lib::full_math;

// ========================================================================
// Constants
// ========================================================================

/// Q64.64 format constants
const Q64: u128 = 18446744073709551616; // 2^64

/// Q96 format constant (used for sqrtPriceX96)
const Q96: u128 = 79228162514264337593543950336; // 2^96

/// Q128 format constant
const Q128: u256 = 340282366920938463463374607431768211456; // 2^128

/// Maximum values for each format
const MAX_Q64_64: u128 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
const MAX_Q64_96: u256 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
const MAX_Q128_128: u256 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;

// ========================================================================
// Error Codes
// ========================================================================

const EOVERFLOW: u64 = 1;
const EUNDERFLOW: u64 = 2;
const EDIVISION_BY_ZERO: u64 = 3;
const EINVALID_CONVERSION: u64 = 4;
const ESQRT_NEGATIVE: u64 = 5;

// ========================================================================
// Type-Safe Wrappers
// ========================================================================

/// Q64.64 fixed-point number (128 bits total)
public struct Q64_64 has copy, drop, store {
    value: u128,
}

/// Q64.96 fixed-point number (160 bits total) - Used for sqrtPriceX96
public struct Q64_96 has copy, drop, store {
    value: u256,
}

/// Q128.128 fixed-point number (256 bits total)
public struct Q128_128 has copy, drop, store {
    value: u256,
}

// ========================================================================
// Q64.64 Operations
// ========================================================================

/// Create Q64.64 from integer (fractional part = 0)
public fun from_int_q64_64(value: u64): Q64_64 {
    Q64_64 {
        value: (value as u128) << 64,
    }
}

/// Create Q64.64 from raw value
public fun from_raw_q64_64(raw: u128): Q64_64 {
    Q64_64 { value: raw }
}

/// Get raw value from Q64.64
public fun to_raw_q64_64(num: Q64_64): u128 {
    num.value
}

/// Convert Q64.64 to integer (truncate fractional part)
public fun to_int_q64_64(num: Q64_64): u64 {
    (num.value >> 64) as u64
}

/// Get fractional part of Q64.64
public fun get_fractional_q64_64(num: Q64_64): u64 {
    (num.value & 0xFFFFFFFFFFFFFFFF) as u64
}

/// Create Q64.64 from integer and fractional parts
/// Example: from_parts(5, Q64/2) = 5.5 in Q64.64
public fun from_parts_q64_64(integer: u64, fractional: u64): Q64_64 {
    Q64_64 {
        value: ((integer as u128) << 64) | (fractional as u128),
    }
}

/// Add two Q64.64 numbers
public fun add_q64_64(a: Q64_64, b: Q64_64): Q64_64 {
    let result = a.value + b.value;
    assert!(result >= a.value, EOVERFLOW); // Check for overflow
    Q64_64 { value: result }
}

/// Subtract two Q64.64 numbers
public fun sub_q64_64(a: Q64_64, b: Q64_64): Q64_64 {
    assert!(a.value >= b.value, EUNDERFLOW);
    Q64_64 { value: a.value - b.value }
}

/// Multiply two Q64.64 numbers
/// Formula: (a × b) / 2^64
public fun mul_q64_64(a: Q64_64, b: Q64_64): Q64_64 {
    // Use u256 to prevent overflow during multiplication
    let product = (a.value as u256) * (b.value as u256);
    let result = product >> 64;

    assert!(result <= (MAX_Q64_64 as u256), EOVERFLOW);
    Q64_64 { value: (result as u128) }
}

/// Divide two Q64.64 numbers
/// Formula: (a × 2^64) / b
public fun div_q64_64(a: Q64_64, b: Q64_64): Q64_64 {
    assert!(b.value != 0, EDIVISION_BY_ZERO);

    // Multiply a by 2^64 first (shift left 64), then divide
    let numerator = (a.value as u256) << 64;
    let result = numerator / (b.value as u256);

    assert!(result <= (MAX_Q64_64 as u256), EOVERFLOW);
    Q64_64 { value: (result as u128) }
}

/// Compare Q64.64 numbers: returns true if a < b
public fun less_than_q64_64(a: Q64_64, b: Q64_64): bool {
    a.value < b.value
}

/// Compare Q64.64 numbers: returns true if a <= b
public fun less_than_or_equal_q64_64(a: Q64_64, b: Q64_64): bool {
    a.value <= b.value
}

/// Compare Q64.64 numbers: returns true if a == b
public fun equal_q64_64(a: Q64_64, b: Q64_64): bool {
    a.value == b.value
}

// ========================================================================
// Q64.96 Operations (Uniswap v3's sqrtPriceX96 format)
// ========================================================================

/// Create Q64.96 from integer
public fun from_int_q64_96(value: u64): Q64_96 {
    Q64_96 {
        value: (value as u256) * (Q96 as u256),
    }
}

/// Create Q64.96 from raw value
public fun from_raw_q64_96(raw: u256): Q64_96 {
    Q64_96 { value: raw }
}

/// Get raw value from Q64.96
public fun to_raw_q64_96(num: Q64_96): u256 {
    num.value
}

/// Convert Q64.96 to integer (truncate fractional part)
public fun to_int_q64_96(num: Q64_96): u64 {
    ((num.value as u256) / (Q96 as u256)) as u64
}

/// Add two Q64.96 numbers
public fun add_q64_96(a: Q64_96, b: Q64_96): Q64_96 {
    let result = (a.value as u256) + (b.value as u256);
    assert!(result <= (MAX_Q64_96 as u256), EOVERFLOW);
    Q64_96 { value: (result as u256) }
}

/// Subtract two Q64.96 numbers
public fun sub_q64_96(a: Q64_96, b: Q64_96): Q64_96 {
    assert!(a.value >= b.value, EUNDERFLOW);
    Q64_96 { value: a.value - b.value }
}

/// Multiply two Q64.96 numbers
/// Formula: (a × b) / 2^96
public fun mul_q64_96(a: Q64_96, b: Q64_96): Q64_96 {
    let product = full_math::mul_div(
        (a.value as u256),
        (b.value as u256),
        (Q96 as u256),
    );

    assert!(product <= (MAX_Q64_96 as u256), EOVERFLOW);
    Q64_96 { value: (product as u256) }
}

/// Divide two Q64.96 numbers
/// Formula: (a × 2^96) / b
public fun div_q64_96(a: Q64_96, b: Q64_96): Q64_96 {
    assert!(b.value != 0, EDIVISION_BY_ZERO);

    let result = full_math::mul_div(
        (a.value as u256),
        (Q96 as u256),
        (b.value as u256),
    );

    assert!(result <= (MAX_Q64_96 as u256), EOVERFLOW);
    Q64_96 { value: (result as u256) }
}

/// Compare Q64.96 numbers
public fun less_than_q64_96(a: Q64_96, b: Q64_96): bool {
    a.value < b.value
}

/// Square a Q64.96 number (useful for converting sqrtPrice to price)
/// Formula: (a × a) / 2^96
public fun square_q64_96(a: Q64_96): Q64_96 {
    mul_q64_96(a, a)
}

// ========================================================================
// Q128.128 Operations (Maximum precision)
// ========================================================================

/// Create Q128.128 from integer
public fun from_int_q128_128(value: u128): Q128_128 {
    Q128_128 {
        value: (value as u256) << 128,
    }
}

/// Create Q128.128 from raw value
public fun from_raw_q128_128(raw: u256): Q128_128 {
    Q128_128 { value: raw }
}

/// Get raw value from Q128.128
public fun to_raw_q128_128(num: Q128_128): u256 {
    num.value
}

/// Convert Q128.128 to integer
public fun to_int_q128_128(num: Q128_128): u128 {
    (num.value >> 128) as u128
}

/// Add two Q128.128 numbers
public fun add_q128_128(a: Q128_128, b: Q128_128): Q128_128 {
    let result = a.value + b.value;
    assert!(result >= a.value, EOVERFLOW);
    Q128_128 { value: result }
}

/// Subtract two Q128.128 numbers
public fun sub_q128_128(a: Q128_128, b: Q128_128): Q128_128 {
    assert!(a.value >= b.value, EUNDERFLOW);
    Q128_128 { value: a.value - b.value }
}

/// Multiply two Q128.128 numbers
/// Note: This is expensive and can overflow - use with caution
public fun mul_q128_128(a: Q128_128, b: Q128_128): Q128_128 {
    // For Q128.128, we need 512-bit intermediate storage
    // We approximate using full_math's 256-bit operations

    // Split into high and low parts
    let a_high = a.value >> 128;
    let a_low = a.value & ((1u256 << 128) - 1);
    let b_high = b.value >> 128;
    let b_low = b.value & ((1u256 << 128) - 1);

    // (a_high + a_low/2^128) × (b_high + b_low/2^128)
    // = a_high × b_high + (a_high × b_low + a_low × b_high)/2^128 + (a_low × b_low)/2^256

    let high_prod = a_high * b_high;
    let mid_prod1 = full_math::mul_div(a_high, b_low, Q128);
    let mid_prod2 = full_math::mul_div(a_low, b_high, Q128);
    let low_prod = full_math::mul_div(a_low, b_low, Q128);

    let result = high_prod + mid_prod1 + mid_prod2 + (low_prod >> 128);

    Q128_128 { value: result }
}

/// Divide two Q128.128 numbers
public fun div_q128_128(a: Q128_128, b: Q128_128): Q128_128 {
    assert!(b.value != 0, EDIVISION_BY_ZERO);

    // This is complex for 128.128 - use approximation
    // (a × 2^128) / b
    let result = full_math::mul_div(a.value, Q128, b.value);

    Q128_128 { value: result }
}

// ========================================================================
// Conversion Functions
// ========================================================================

/// Convert Q64.64 to Q64.96
public fun q64_64_to_q64_96(num: Q64_64): Q64_96 {
    // Multiply by 2^32 (96 - 64 = 32)
    let result = (num.value as u256) << 32;
    assert!(result <= (MAX_Q64_96 as u256), EOVERFLOW);
    Q64_96 { value: (result as u256) }
}

/// Convert Q64.96 to Q64.64 (loses precision)
public fun q64_96_to_q64_64(num: Q64_96): Q64_64 {
    // Divide by 2^32
    let result = (num.value as u128) >> 32;
    Q64_64 { value: result }
}

/// Convert Q64.64 to Q128.128
public fun q64_64_to_q128_128(num: Q64_64): Q128_128 {
    // Multiply by 2^64 (128 - 64 = 64)
    let result = (num.value as u256) << 64;
    Q128_128 { value: result }
}

/// Convert Q128.128 to Q64.64 (may lose precision)
public fun q128_128_to_q64_64(num: Q128_128): Q64_64 {
    let result = num.value >> 64;
    assert!(result <= (MAX_Q64_64 as u256), EOVERFLOW);
    Q64_64 { value: (result as u128) }
}

/// Convert Q64.96 to Q128.128
public fun q64_96_to_q128_128(num: Q64_96): Q128_128 {
    // Multiply by 2^32 (128 - 96 = 32)
    let result = (num.value as u256) << 32;
    Q128_128 { value: result }
}

/// Convert Q128.128 to Q64.96 (may lose precision)
public fun q128_128_to_q64_96(num: Q128_128): Q64_96 {
    let result = num.value >> 32;
    assert!(result <= (MAX_Q64_96 as u256), EOVERFLOW);
    Q64_96 { value: (result as u256) }
}

// ========================================================================
// Advanced Operations
// ========================================================================

/// Calculate square root of Q64.64 using Newton-Raphson
/// Returns Q64.64 result
public fun sqrt_q64_64(num: Q64_64): Q64_64 {
    if (num.value == 0) {
        return Q64_64 { value: 0 }
    };

    // Newton-Raphson: x_{n+1} = (x_n + N/x_n) / 2
    // Start with a reasonable guess
    let mut x = num.value;

    // Initial guess: approximate sqrt by right shifting
    let mut guess = num.value >> 32; // Rough approximation
    if (guess == 0) {
        guess = 1;
    };

    // Iterate until convergence (typically 5-6 iterations)
    let mut i = 0;
    while (i < 10) {
        let next_guess = (guess + (x / guess)) / 2;
        if (next_guess == guess) {
            break
        };
        guess = next_guess;
        i = i + 1;
    };

    // Result needs to be scaled back to Q64.64
    // Since we divided by sqrt, we need to multiply by sqrt(2^64) = 2^32
    Q64_64 { value: guess << 32 }
}

/// Calculate square root of Q64.96 (used for sqrtPrice calculations)
public fun sqrt_q64_96(num: Q64_96): Q64_96 {
    if (num.value == 0) {
        return Q64_96 { value: 0 }
    };

    // Newton-Raphson for Q64.96
    let x = num.value as u256;
    let mut guess = x >> 48; // Initial guess

    if (guess == 0) {
        guess = 1;
    };

    let mut i = 0;
    while (i < 10) {
        let next_guess = (guess + (x / guess)) / 2;
        if (next_guess == guess) {
            break
        };
        guess = next_guess;
        i = i + 1;
    };

    // Scale back to Q64.96: multiply by 2^48
    let result = guess << 48;
    assert!(result <= (MAX_Q64_96 as u256), EOVERFLOW);

    Q64_96 { value: (result as u256) }
}

/// Reciprocal of Q64.64: 1/x
public fun reciprocal_q64_64(num: Q64_64): Q64_64 {
    assert!(num.value != 0, EDIVISION_BY_ZERO);

    // 1/x = 2^128 / (x × 2^64) = 2^64 / x
    let numerator = (Q64 as u256) * (Q64 as u256);
    let result = numerator / (num.value as u256);

    assert!(result <= (MAX_Q64_64 as u256), EOVERFLOW);
    Q64_64 { value: (result as u128) }
}

/// Multiply Q64.96 by u128 (useful for liquidity calculations)
public fun mul_q64_96_u128(fp: Q64_96, integer: u128): u256 {
    full_math::mul_div(
        (fp.value as u256),
        (integer as u256),
        (Q96 as u256),
    )
}

/// Divide u256 by Q64.96 to get u256 result
public fun div_u256_by_q64_96(numerator: u256, fp: Q64_96): u256 {
    assert!(fp.value != 0, EDIVISION_BY_ZERO);

    full_math::mul_div(
        numerator,
        (Q96 as u256),
        (fp.value as u256),
    )
}

// ========================================================================
// Helper Functions
// ========================================================================

/// Get Q64 constant
public fun get_q64(): u128 {
    Q64
}

/// Get Q96 constant
public fun get_q96(): u128 {
    Q96
}

/// Get Q128 constant
public fun get_q128(): u256 {
    Q128
}

// ========================================================================
// Tests
// ========================================================================

#[test]
fun test_q64_64_from_int() {
    let five = from_int_q64_64(5);
    assert!(to_int_q64_64(five) == 5, 0);
    assert!(get_fractional_q64_64(five) == 0, 1);
}

#[test]
fun test_q64_64_addition() {
    let two = from_int_q64_64(2);
    let three = from_int_q64_64(3);
    let five = add_q64_64(two, three);
    assert!(to_int_q64_64(five) == 5, 0);
}

#[test]
fun test_q64_64_subtraction() {
    let five = from_int_q64_64(5);
    let two = from_int_q64_64(2);
    let three = sub_q64_64(five, two);
    assert!(to_int_q64_64(three) == 3, 0);
}

#[test]
fun test_q64_64_multiplication() {
    let two = from_int_q64_64(2);
    let three = from_int_q64_64(3);
    let six = mul_q64_64(two, three);
    assert!(to_int_q64_64(six) == 6, 0);
}

#[test]
fun test_q64_64_division() {
    let six = from_int_q64_64(6);
    let two = from_int_q64_64(2);
    let three = div_q64_64(six, two);
    assert!(to_int_q64_64(three) == 3, 0);
}

#[test]
fun test_q64_64_fractional() {
    // Create 2.5 = 2 + 0.5
    // 0.5 in Q64 = 2^64 / 2 = 2^63
    let half = Q64 >> 1;
    let two_point_five = from_parts_q64_64(2, half as u64);

    assert!(to_int_q64_64(two_point_five) == 2, 0);
    assert!((get_fractional_q64_64(two_point_five) as u128) == half, 1);
}

#[test]
fun test_q64_64_comparison() {
    let two = from_int_q64_64(2);
    let three = from_int_q64_64(3);

    assert!(less_than_q64_64(two, three), 0);
    assert!(!less_than_q64_64(three, two), 1);
    assert!(equal_q64_64(two, two), 2);
}

#[test]
fun test_q64_96_operations() {
    let one = from_int_q64_96(1);
    let two = from_int_q64_96(2);

    let three = add_q64_96(one, two);
    assert!(to_int_q64_96(three) == 3, 0);

    let product = mul_q64_96(two, three);
    assert!(to_int_q64_96(product) == 6, 1);
}

#[test]
fun test_q64_96_square() {
    let two = from_int_q64_96(2);
    let four = square_q64_96(two);
    assert!(to_int_q64_96(four) == 4, 0);
}

#[test]
fun test_q64_64_sqrt() {
    let four = from_int_q64_64(4);
    let two = sqrt_q64_64(four);

    // Result should be close to 2.0
    let result_int = to_int_q64_64(two);
    assert!(result_int == 2 || result_int == 1, 0); // Allow for rounding
}

#[test]
fun test_q64_64_reciprocal() {
    let two = from_int_q64_64(2);
    let half = reciprocal_q64_64(two);

    // 1/2 = 0.5, so integer part should be 0
    assert!(to_int_q64_64(half) == 0, 0);

    // Fractional part should be approximately 2^63
    let frac = get_fractional_q64_64(half);
    let expected = Q64 >> 1;
    assert!((frac as u128) == expected, 1);
}

#[test]
fun test_conversion_q64_64_to_q64_96() {
    let five = from_int_q64_64(5);
    let five_96 = q64_64_to_q64_96(five);
    assert!(to_int_q64_96(five_96) == 5, 0);
}

#[test]
fun test_conversion_q64_96_to_q64_64() {
    let five = from_int_q64_96(5);
    let five_64 = q64_96_to_q64_64(five);
    assert!(to_int_q64_64(five_64) == 5, 0);
}

#[test]
fun test_q128_128_operations() {
    let one = from_int_q128_128(1);
    let two = from_int_q128_128(2);

    let three = add_q128_128(one, two);
    assert!(to_int_q128_128(three) == 3, 0);

    let one_again = sub_q128_128(three, two);
    assert!(to_int_q128_128(one_again) == 1, 1);
}

#[test]
fun test_mul_q64_96_u128() {
    // 2.0 (in Q64.96) × 5 = 10
    let two = from_int_q64_96(2);
    let result = mul_q64_96_u128(two, 5);
    assert!(result == 10, 0);
}

#[test]
#[expected_failure(abort_code = EDIVISION_BY_ZERO)]
fun test_division_by_zero_q64_64() {
    let five = from_int_q64_64(5);
    let zero = from_int_q64_64(0);
    div_q64_64(five, zero);
}

#[test]
#[expected_failure(abort_code = EUNDERFLOW)]
fun test_underflow_q64_64() {
    let two = from_int_q64_64(2);
    let five = from_int_q64_64(5);
    sub_q64_64(two, five); // 2 - 5 = underflow
}

#[test]
fun test_realistic_price_calculation() {
    // Simulate a price of 1.0001 (one tick up)
    // In Q64.96: 1.0001 × 2^96
    let base_price = from_int_q64_96(1);
    let tick_increment = Q96 as u256 / 10000; // 0.0001
    let price_one_tick_up = from_raw_q64_96(
        (base_price.value as u256 + tick_increment as u256) as u256,
    );

    // Price should be slightly above 1.0
    assert!(to_int_q64_96(price_one_tick_up) == 1, 0);
    assert!(price_one_tick_up.value > base_price.value, 1);
}
