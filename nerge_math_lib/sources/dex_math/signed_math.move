/// Signed integer arithmetic for Uniswap v3-style DEX
///
/// Move has no native signed integer types, so we implement them using
/// two's complement representation. This module provides i32, i128, and i256.
///
/// Two's Complement Refresher:
/// - Positive numbers: 0 to MAX (high bit = 0)
/// - Negative numbers: MIN to -1 (high bit = 1)
/// - Negation: flip all bits and add 1
///
/// Example (i32 using u32):
///   5 = 0x00000005
///  -5 = 0xFFFFFFFB (flip bits: 0xFFFFFFFA, add 1: 0xFFFFFFFB)
module nerge_math_lib::signed_math;

use nerge_math_lib::bitwise_complement;

#[test_only]
use std::debug;

#[test_only]
use std::string;

// ========================================================================
// Constants
// ========================================================================

/// i32 constants
const I32_MIN: u32 = 0x80000000; // -2,147,483,648
const I32_MAX: u32 = 0x7FFFFFFF; //  2,147,483,647
const MAX_U32: u32 = 0xFFFFFFFFu32;
const MASK32_U64: u64 = (1u64 << 32) - 1u64;

/// i128 constants
const I128_MIN: u128 = 0x80000000000000000000000000000000;
const I128_MAX: u128 = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
const MAX_U128: u128 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFu128;
const MASK128_U256: u256 = (1u256 << 128) - 1u256;

/// i256 constants (stored as u256)
const I256_MIN_HIGH: u128 = 0x80000000000000000000000000000000;
const I256_MAX_HIGH: u128 = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;

// ========================================================================
// Error Codes
// ========================================================================

const EOVERFLOW: u64 = 1;
const EUNDERFLOW: u64 = 2;
const EDIVISION_BY_ZERO: u64 = 3;
const EINVALID_CONVERSION: u64 = 4;

// ========================================================================
// i32 Implementation
// ========================================================================

/// Check if i32 value is negative
public fun is_negative_i32(value: u32): bool {
    value >= I32_MIN
}

/// Check if i32 value is positive (excluding zero)
public fun is_positive_i32(value: u32): bool {
    value > 0 && value < I32_MIN
}

/// Check if i32 value is zero
public fun is_zero_i32(value: u32): bool {
    value == 0
}

/// Negate i32 value: -x
/// Special case: -I32_MIN = I32_MIN (overflow wraps in two's complement)
public fun negate_i32(value: u32): u32 {
    if (value == 0) {
        return 0
    };

    // Two's complement negation: flip bits and add 1
    // This works because: x + (~x + 1) = 0 (mod 2^32)
    // (~value) + 1
    let complement = bitwise_complement::bitwise_complement_u32(value);

    complement + 1
}

/// Absolute value of i32
/// Returns u32 as the magnitude (always non-negative)
public fun abs_i32(value: u32): u32 {
    if (is_negative_i32(value)) {
        negate_i32(value)
    } else {
        value
    }
}

/// Add two i32 values with overflow checking
public fun add_i32(a: u32, b: u32): u32 {
    // Use u64 to detect unsigned overflow
    let result = (a as u64) + (b as u64);

    // KEEP LOW 32 BITS (wrap). Do this while still u64 so cast won't abort.
    let wrapped_u64: u64 = result & MASK32_U64; // wrap modulo 2^32
    let result_32 = (wrapped_u64 as u32);

    // Check unsigned overflow (shouldn't happen in normal cases)
    assert!(result_32 <= MAX_U32, EOVERFLOW);

    // Check signed overflow
    // Overflow occurs when:
    // - Two positive numbers sum to a negative (pos + pos = neg)
    // - Two negative numbers sum to a positive (neg + neg = pos)
    let a_neg = is_negative_i32(a);
    let b_neg = is_negative_i32(b);
    let result_neg = is_negative_i32(result_32);

    if (!a_neg && !b_neg && result_neg) {
        abort EOVERFLOW // positive + positive = negative
    };
    if (a_neg && b_neg && !result_neg) {
        abort EUNDERFLOW // negative + negative = positive
    };

    result_32
}

/// Subtract two i32 values: a - b
public fun sub_i32(a: u32, b: u32): u32 {
    // Subtraction is addition with negated second operand
    add_i32(a, negate_i32(b))
}

/// Multiply two i32 values with overflow checking
public fun mul_i32(a: u32, b: u32): u32 {
    // Handle zero cases early
    if (a == 0 || b == 0) {
        return 0
    };

    // Determine result sign
    let result_negative = is_negative_i32(a) != is_negative_i32(b);

    // Multiply absolute values using u64 to detect overflow
    let abs_a = (abs_i32(a) as u64);
    let abs_b = (abs_i32(b) as u64);
    let abs_result = abs_a * abs_b;

    // Check if result fits in i32 range
    if (result_negative) {
        // Negative result: must fit in I32_MIN to -1
        // abs(I32_MIN) = 2^31, so abs_result must be <= 2^31
        assert!(abs_result <= (I32_MIN as u64), EOVERFLOW);
        let result = (abs_result as u32);
        negate_i32(result)
    } else {
        // Positive result: must fit in 0 to I32_MAX
        assert!(abs_result <= (I32_MAX as u64), EOVERFLOW);
        (abs_result as u32)
    }
}

/// Divide two i32 values: a / b (truncated toward zero)
public fun div_i32(a: u32, b: u32): u32 {
    assert!(b != 0, EDIVISION_BY_ZERO);

    // Handle zero dividend
    if (a == 0) {
        return 0
    };

    // Determine result sign
    let result_negative = is_negative_i32(a) != is_negative_i32(b);

    // Divide absolute values
    let abs_result = abs_i32(a) / abs_i32(b);

    if (result_negative) {
        negate_i32(abs_result)
    } else {
        abs_result
    }
}

/// Compare two i32 values: returns -1 if a < b, 0 if a == b, 1 if a > b
public fun cmp_i32(a: u32, b: u32): u8 {
    if (a == b) {
        return 0
    };

    if (less_than_i32(a, b)) {
        return 0 // We'll use 0 for less than (can't return -1 as u8)
    } else {
        return 1
    }
}

/// Check if a < b for i32 values
public fun less_than_i32(a: u32, b: u32): bool {
    let a_neg = is_negative_i32(a);
    let b_neg = is_negative_i32(b);

    if (a_neg && !b_neg) {
        true // negative < positive
    } else if (!a_neg && b_neg) {
        false // positive > negative
    } else {
        // Same sign: compare as unsigned
        // For negatives, more negative = smaller unsigned value
        // For positives, normal unsigned comparison
        a < b
    }
}

/// Check if a <= b for i32 values
public fun less_than_or_equal_i32(a: u32, b: u32): bool {
    a == b || less_than_i32(a, b)
}

/// Check if a > b for i32 values
public fun greater_than_i32(a: u32, b: u32): bool {
    !less_than_or_equal_i32(a, b)
}

/// Check if a >= b for i32 values
public fun greater_than_or_equal_i32(a: u32, b: u32): bool {
    !less_than_i32(a, b)
}

/// Convert i32 to i64 with sign extension
public fun to_i64(value: u32): u64 {
    if (is_negative_i32(value)) {
        // Sign extend: fill upper 32 bits with 1s
        0xFFFFFFFF00000000 | (value as u64)
    } else {
        // Zero extend: upper bits already 0
        (value as u64)
    }
}

/// Convert i32 to i128 with sign extension
public fun to_i128(value: u32): u128 {
    if (is_negative_i32(value)) {
        // Sign extend: fill upper 96 bits with 1s
        0xFFFFFFFFFFFFFFFFFFFFFFFF00000000 | (value as u128)
    } else {
        (value as u128)
    }
}

/// Create i32 from literal value (helper for testing)
/// Takes a signed interpretation: positive values 0 to I32_MAX
public fun from_literal_i32(value: u32): u32 {
    assert!(value <= I32_MAX, EINVALID_CONVERSION);
    value
}

/// Create negative i32 from magnitude
public fun from_negative_i32(magnitude: u32): u32 {
    assert!(magnitude <= I32_MAX, EINVALID_CONVERSION);
    if (magnitude == 0) {
        0
    } else {
        negate_i32(magnitude)
    }
}

// ========================================================================
// i128 Implementation
// ========================================================================

/// Check if i128 value is negative
public fun is_negative_i128(value: u128): bool {
    value >= I128_MIN
}

/// Negate i128 value
public fun negate_i128(value: u128): u128 {
    if (value == 0) {
        return 0
    };

    // (!value) + 1
    let complement = bitwise_complement::bitwise_complement_u128(value);

    complement + 1
}

/// Absolute value of i128
public fun abs_i128(value: u128): u128 {
    if (is_negative_i128(value)) {
        negate_i128(value)
    } else {
        value
    }
}

/// Add two i128 values with overflow checking
public fun add_i128(a: u128, b: u128): u128 {
    // Use u256 to detect unsigned overflow
    let result = (a as u256) + (b as u256);

    // Check unsigned overflow
    // let max_ovr: u128 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFu128;

    // KEEP LOW 128 BITS (wrap). Do this while still u256 so cast won't abort.
    let wrapped_u256: u256 = result & MASK128_U256; // wrap modulo 2^128
    let result_128 = (wrapped_u256 as u128);

    assert!(result_128 <= MAX_U128, EOVERFLOW);

    // Check signed overflow
    let a_neg = is_negative_i128(a);
    let b_neg = is_negative_i128(b);
    let result_neg = is_negative_i128(result_128);

    if (!a_neg && !b_neg && result_neg) {
        abort EOVERFLOW
    };
    if (a_neg && b_neg && !result_neg) {
        abort EUNDERFLOW
    };

    result_128
}

/// Subtract two i128 values
public fun sub_i128(a: u128, b: u128): u128 {
    add_i128(a, negate_i128(b))
}

/// Multiply two i128 values with overflow checking
public fun mul_i128(a: u128, b: u128): u128 {
    if (a == 0 || b == 0) {
        return 0
    };

    let result_negative = is_negative_i128(a) != is_negative_i128(b);

    let abs_a = (abs_i128(a) as u256);
    let abs_b = (abs_i128(b) as u256);
    let abs_result = abs_a * abs_b;

    if (result_negative) {
        assert!(abs_result <= (I128_MIN as u256), EOVERFLOW);
        let result = (abs_result as u128);
        negate_i128(result)
    } else {
        assert!(abs_result <= (I128_MAX as u256), EOVERFLOW);
        (abs_result as u128)
    }
}

/// Divide two i128 values
public fun div_i128(a: u128, b: u128): u128 {
    assert!(b != 0, EDIVISION_BY_ZERO);

    if (a == 0) {
        return 0
    };

    let result_negative = is_negative_i128(a) != is_negative_i128(b);
    let abs_result = abs_i128(a) / abs_i128(b);

    if (result_negative) {
        negate_i128(abs_result)
    } else {
        abs_result
    }
}

/// Check if a < b for i128 values
public fun less_than_i128(a: u128, b: u128): bool {
    let a_neg = is_negative_i128(a);
    let b_neg = is_negative_i128(b);

    if (a_neg && !b_neg) {
        true
    } else if (!a_neg && b_neg) {
        false
    } else {
        a < b
    }
}

/// Convert i128 to i256 with sign extension
public fun to_i256(value: u128): u256 {
    if (is_negative_i128(value)) {
        // Sign extend
        let upper = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF_u128;
        let lower = value;
        ((upper as u256) << 128) | (lower as u256)
    } else {
        (value as u256)
    }
}

// ========================================================================
// i256 Implementation
// ========================================================================

/// Check if i256 value is negative (check high bit)
public fun is_negative_i256(value: u256): bool {
    // Check if the highest bit (bit 255) is set
    value >= ((I256_MIN_HIGH as u256) << 128)
}

/// Negate i256 value
public fun negate_i256(value: u256): u256 {
    if (value == 0) {
        return 0
    };

    // (!value) + 1
    let complement = bitwise_complement::bitwise_complement_u256(value);

    complement + 1
}

/// Absolute value of i256
public fun abs_i256(value: u256): u256 {
    if (is_negative_i256(value)) {
        negate_i256(value)
    } else {
        value
    }
}

/// Add two i256 values (no overflow check - wraps)
/// Note: In production, you may want to add overflow detection
public fun add_i256(a: u256, b: u256): u256 {
    // For i256, we accept wrapping behavior like Solidity
    // To add overflow checking, you'd need to implement carry detection
    a + b
}

/// Subtract two i256 values
public fun sub_i256(a: u256, b: u256): u256 {
    add_i256(a, negate_i256(b))
}

/// Check if a < b for i256 values
public fun less_than_i256(a: u256, b: u256): bool {
    let a_neg = is_negative_i256(a);
    let b_neg = is_negative_i256(b);

    if (a_neg && !b_neg) {
        true
    } else if (!a_neg && b_neg) {
        false
    } else {
        a < b
    }
}

// ========================================================================
// Tests
// ========================================================================

#[test]
fun test_i32_basic_operations() {
    // Test positive numbers
    assert!(add_i32(5, 3) == 8, 0);
    assert!(sub_i32(5, 3) == 2, 1);
    assert!(mul_i32(5, 3) == 15, 2);
    assert!(div_i32(15, 3) == 5, 3);
}

#[test]
fun test_i32_negative_operations() {
    let neg_5 = negate_i32(5);
    let neg_3 = negate_i32(3);

    // -5 + 3 = -2
    let result = add_i32(neg_5, 3);
    assert!(is_negative_i32(result), 0);
    assert!(abs_i32(result) == 2, 1);

    // 5 + (-3) = 2
    assert!(add_i32(5, neg_3) == 2, 2);

    // -5 + (-3) = -8
    let result = add_i32(neg_5, neg_3);
    assert!(is_negative_i32(result), 3);
    assert!(abs_i32(result) == 8, 4);

    // -5 - 3 = -8
    let result = sub_i32(neg_5, 3);
    assert!(abs_i32(result) == 8, 5);

    // -5 * 3 = -15
    let result = mul_i32(neg_5, 3);
    assert!(is_negative_i32(result), 6);
    assert!(abs_i32(result) == 15, 7);

    // -15 / 3 = -5
    let neg_15 = negate_i32(15);
    let result = div_i32(neg_15, 3);
    assert!(is_negative_i32(result), 8);
    assert!(abs_i32(result) == 5, 9);
}

#[test]
fun test_i32_comparison() {
    let neg_5 = negate_i32(5);
    let neg_3 = negate_i32(3);

    // -5 < -3
    assert!(less_than_i32(neg_5, neg_3), 0);

    // -5 < 3
    assert!(less_than_i32(neg_5, 3), 1);

    // 3 > -5
    assert!(greater_than_i32(3, neg_5), 2);

    // 5 > 3
    assert!(greater_than_i32(5, 3), 3);
}

#[test]
fun test_i32_sign_extension() {
    let neg_5 = negate_i32(5);

    // Convert to i64 and check
    let i64_value = to_i64(neg_5);
    assert!(i64_value >= 0xFFFFFFFF00000000, 0);

    // Positive value sign extension
    let i64_pos = to_i64(5);
    assert!(i64_pos == 5, 1);
}

#[test]
fun test_i32_edge_cases() {
    // Test zero
    assert!(add_i32(0, 0) == 0, 0);
    assert!(negate_i32(0) == 0, 1);
    assert!(abs_i32(0) == 0, 2);

    // Test I32_MAX
    assert!(!is_negative_i32(I32_MAX), 3);
    assert!(abs_i32(I32_MAX) == I32_MAX, 4);

    // Test I32_MIN behavior
    assert!(is_negative_i32(I32_MIN), 5);
    // Note: negate(I32_MIN) = I32_MIN in two's complement
    assert!(negate_i32(I32_MIN) == I32_MIN, 6);
}

#[test]
#[expected_failure(abort_code = EOVERFLOW)]
fun test_i32_overflow() {
    // I32_MAX + 1 should overflow
    add_i32(I32_MAX, 1);
}

#[test]
#[expected_failure(abort_code = EUNDERFLOW)]
fun test_i32_underflow() {
    // I32_MIN - 1 should underflow
    sub_i32(I32_MIN, 1);
}

#[test]
#[expected_failure(abort_code = EDIVISION_BY_ZERO)]
fun test_i32_division_by_zero() {
    div_i32(5, 0);
}

#[test]
fun test_i128_operations() {
    let a: u128 = 1000000000;
    let b: u128 = 2000000000;

    assert!(add_i128(a, b) == 3000000000, 0);
    assert!(sub_i128(b, a) == 1000000000, 1);
    assert!(mul_i128(a, 2) == 2000000000, 2);

    // debugging

    let neg_a = negate_i128(a);
    assert!(is_negative_i128(neg_a), 3);
    assert!(abs_i128(neg_a) == a, 4);
}

#[test]
fun test_i256_operations() {
    let a: u256 = 1000000000000000000;
    let b: u256 = 2000000000000000000;

    assert!(add_i256(a, b) == 3000000000000000000, 0);

    let neg_a = negate_i256(a);
    assert!(is_negative_i256(neg_a), 1);
    assert!(abs_i256(neg_a) == a, 2);

    assert!(less_than_i256(neg_a, a), 3);
}

#[test]
fun test_tick_range_simulation() {
    // Simulate Uniswap v3 tick range: -887272 to 887272
    let min_tick = from_negative_i32(887272);
    let max_tick = from_literal_i32(887272);

    assert!(is_negative_i32(min_tick), 0);
    assert!(!is_negative_i32(max_tick), 1);

    // Test tick arithmetic
    let tick_spacing = 60;
    let current_tick = from_literal_i32(1000);
    let next_tick = add_i32(current_tick, tick_spacing);
    assert!(next_tick == 1060, 2);

    // Negative tick addition
    let neg_tick = from_negative_i32(500);
    let result = add_i32(neg_tick, tick_spacing);
    // -500 + 60 = -440
    assert!(is_negative_i32(result), 3);
    assert!(abs_i32(result) == 440, 4);
}
