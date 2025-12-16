/// Full Math - High precision multiplication and division
///
/// Provides 256-bit multiplication and division operations that are
/// critical for Uniswap v3 liquidity calculations.
///
/// Key Operations:
/// - mul_div: (a * b) / c with full 512-bit intermediate precision
/// - mul_div_rounding_up: Same but rounds up instead of down
///
/// Why needed?
/// - (u256 * u256) can overflow u256, so we need special handling
/// - Division must happen after multiplication to maintain precision
/// - Rounding direction matters for protocol safety
module nerge_math_lib::full_math;

#[test_only]
use std::debug;

#[test_only]
use std::string;

// ========================================================================
// Error Codes
// ========================================================================

const EDIVISION_BY_ZERO: u64 = 1;
const EOVERFLOW: u64 = 2;

// ========================================================================
// Core Functions
// ========================================================================

/// Multiply two u256 values and divide by a third with full precision
/// Computes (a * b) / c without overflow in intermediate multiplication
///
/// Algorithm:
/// 1. Split a and b into high/low 128-bit parts
/// 2. Perform multiplication in parts to get 512-bit result
/// 3. Divide the 512-bit result by c
///
/// This is the most critical function for liquidity calculations
public fun mul_div(a: u256, b: u256, denominator: u256): u256 {
    assert!(denominator > 0, EDIVISION_BY_ZERO);

    // Handle simple cases first
    if (a == 0 || b == 0) {
        return 0
    };

    // Fast path: if a * b doesn't overflow u256, use simple division
    let product = a * b;
    if (product / a == b) {
        // No overflow occurred
        return product / denominator
    };

    // Need full 512-bit precision
    // Split a and b into 128-bit halves
    // a = a_high * 2^128 + a_low
    // b = b_high * 2^128 + b_low
    let a_high = a >> 128;
    let a_low = a & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    let b_high = b >> 128;
    let b_low = b & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;

    // Compute a * b in four parts:
    // (a_high * 2^128 + a_low) * (b_high * 2^128 + b_low)
    // = a_high * b_high * 2^256
    //   + (a_high * b_low + a_low * b_high) * 2^128
    //   + a_low * b_low

    let product_ll = a_low * b_low; // Low * Low
    let product_lh = a_low * b_high; // Low * High
    let product_hl = a_high * b_low; // High * Low
    let product_hh = a_high * b_high; // High * High

    // Combine into 512-bit result (stored as two u256 values)
    // product_512 = (product_high << 256) + product_low

    // Start with low part
    let mut product_low = product_ll;
    let mut product_high = product_hh;

    // Add middle terms (they span the 128-bit boundary)
    let middle = product_lh + product_hl;
    let middle_high = middle >> 128;
    let middle_low = middle << 128;

    // Add middle_low to product_low (with carry)
    let (new_product_low, carry) = add_with_carry(product_low, middle_low);
    product_low = new_product_low;
    product_high = product_high + middle_high + (carry as u256);

    // Now divide the 512-bit result by denominator
    // We need to check if result fits in u256

    // If product_high >= denominator, result won't fit in u256
    assert!(product_high < denominator, EOVERFLOW);

    // Perform long division
    // result = (product_high * 2^256 + product_low) / denominator

    // We can use the fact that:
    // (product_high * 2^256 + product_low) / denominator
    // = (product_high * 2^256) / denominator + product_low / denominator
    // But we need to handle this carefully to avoid overflow

    let quotient = div_512_by_256(product_high, product_low, denominator);
    quotient
}

/// Same as mul_div but rounds up instead of truncating
/// Used when we want to favor the protocol over the user
public fun mul_div_rounding_up(a: u256, b: u256, denominator: u256): u256 {
    let result = mul_div(a, b, denominator);

    // Check if there's a remainder
    let remainder = (a * b) % denominator;

    if (remainder > 0) {
        // There's a remainder, so round up
        result + 1
    } else {
        result
    }
}

// ========================================================================
// Helper Functions
// ========================================================================

/// Add two u256 values and return (result, carry_bit)
fun add_with_carry_old(a: u256, b: u256): (u256, u8) {
    let sum = a + b;

    // Carry occurred if sum < a (overflow wrapped around)
    let carry = if (sum < a) { 1 } else { 0 };
    (sum, carry)
}

// Safe u256 add-with-carry implemented by splitting into 128-bit halves.

const MASK128_U256: u256 = (1u256 << 128) - 1u256; // low 128 bits mask
const MASK128_U128: u128 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFu128;

fun u256_low_u128(x: u256): u128 {
    // low 128 bits of x as u128
    (x & MASK128_U256) as u128
}

fun u256_high_u128(x: u256): u128 {
    // high 128 bits of x as u128
    (x >> 128) as u128
}

/// Add two u256 values and return (result_wrapped_mod_2^256, carry_bit)
public fun add_with_carry(a: u256, b: u256): (u256, u8) {
    // split into 128-bit halves (as u128)
    let a_lo: u128 = u256_low_u128(a);
    let a_hi: u128 = u256_high_u128(a);
    let b_lo: u128 = u256_low_u128(b);
    let b_hi: u128 = u256_high_u128(b);

    // add low halves in u256 (safe: sum <= 2*(2^128-1) < 2^129 < u256::MAX)
    let sum_lo_u256: u256 = (a_lo as u256) + (b_lo as u256);

    // detect carry from low half (if sum_lo > 2^128-1)
    let carry_lo: u256 = if (sum_lo_u256 > MASK128_U256) { 1u256 } else { 0u256 };

    // wrapped low half (keep only low 128 bits)
    let res_lo_u128: u128 = (sum_lo_u256 & MASK128_U256) as u128;

    // add high halves + carry_lo (safe in u256)
    let sum_hi_u256: u256 = (a_hi as u256) + (b_hi as u256) + carry_lo;

    // carry out of full 256-bit addition
    let carry_out: u8 = if (sum_hi_u256 > MASK128_U256) { 1u8 } else { 0u8 };

    // wrapped high half (low 128 bits of sum_hi)
    let res_hi_u128: u128 = (sum_hi_u256 & MASK128_U256) as u128;

    // reconstruct final u256 result: (res_hi << 128) | res_lo
    let result: u256 = ((res_hi_u128 as u256) << 128) | (res_lo_u128 as u256);

    (result, carry_out)
}

/// Divide a 512-bit number by a 256-bit number
/// Input: (high_256_bits, low_256_bits) / denominator
/// Output: u256 result
///
/// This implements long division for 512-bit / 256-bit
fun div_512_by_256(high: u256, low: u256, denominator: u256): u256 {
    // We already checked that high < denominator in mul_div

    if (high == 0) {
        // Simple case: just divide low part
        return low / denominator
    };

    // We need to compute: (high * 2^256 + low) / denominator
    //
    // Strategy: Binary long division
    // Start from the most significant bit and work down

    let mut quotient: u256 = 0;
    let mut remainder_high = high;
    let mut remainder_low = low;

    // Process each bit from high to low
    let mut i: u16 = 256;
    while (i > 0) {
        i = i - 1;

        // Shift quotient left by 1
        quotient = quotient << 1;

        // Shift remainder left by 1
        // This is: (remainder_high << 1) | (remainder_low >> 255)
        let bit_from_low = remainder_low >> 255;
        remainder_high = (remainder_high << 1) | bit_from_low;
        remainder_low = remainder_low << 1;

        // If remainder_high >= denominator, subtract and set quotient bit
        if (remainder_high >= denominator) {
            remainder_high = remainder_high - denominator;
            quotient = quotient | 1;
        };
    };

    quotient
}

/// Multiply two u128 values to get u256 result
/// Useful helper for 128-bit math
public fun mul_u128_to_u256(a: u128, b: u128): u256 {
    (a as u256) * (b as u256)
}

/// Safely cast u256 to u128 with overflow check
public fun safe_cast_to_u128(value: u256): u128 {
    assert!(value <= 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF, EOVERFLOW);
    (value as u128)
}

// ========================================================================
// Tests
// ========================================================================

#[test]
fun test_mul_div_simple() {
    // Simple case: (10 * 20) / 5 = 40
    let result = mul_div(10, 20, 5);
    assert!(result == 40, 0);
}

#[test]
fun test_mul_div_with_remainder() {
    // (10 * 21) / 5 = 42
    let result = mul_div(10, 21, 5);
    assert!(result == 42, 0);

    // (10 * 22) / 5 = 44
    let result2 = mul_div(10, 22, 5);
    assert!(result2 == 44, 1);
}

#[test]
fun test_mul_div_rounding_up() {
    // (10 * 21) / 5 = 42 (no rounding needed)
    let result = mul_div_rounding_up(10, 21, 5);
    assert!(result == 42, 0);

    // (10 * 23) / 5 = 46 (rounds up from 45.xxx)
    let result2 = mul_div_rounding_up(10, 23, 5);
    assert!(result2 == 46, 1);
}

#[test]
fun test_mul_div_large_numbers() {
    // Test with numbers that would overflow u128
    let a: u256 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF; // max u128
    let b: u256 = 2;
    let c: u256 = 1;

    let result = mul_div(a, b, c);
    assert!(result == a * 2, 0);
}

#[test]
fun test_mul_div_q96_precision() {
    // Test Q96 fixed point multiplication
    // Simulates: (price * liquidity) / 2^96
    let q96: u256 = 79228162514264337593543950336; // 2^96
    let price = q96 * 2; // Represents 2.0 in Q96
    let liquidity: u256 = 1000000;

    let result = mul_div(price, liquidity, q96);
    assert!(result == 2000000, 0); // 2.0 * 1000000 = 2000000
}

#[test]
fun test_mul_div_zero_cases() {
    assert!(mul_div(0, 100, 10) == 0, 0);
    assert!(mul_div(100, 0, 10) == 0, 1);
}

#[test]
#[expected_failure(abort_code = EDIVISION_BY_ZERO)]
fun test_mul_div_division_by_zero() {
    mul_div(10, 20, 0);
}

#[test]
fun test_mul_div_identity() {
    // (a * b) / b = a
    let a: u256 = 123456789;
    let b: u256 = 987654321;

    let result = mul_div(a, b, b);
    assert!(result == a, 0);
}

#[test]
fun test_add_with_carry() {
    // No carry case
    let (sum1, carry1) = add_with_carry(100, 200);
    assert!(sum1 == 300, 0);
    assert!(carry1 == 0, 1);

    // Carry case (max u256 + 1)
    let max_u256: u256 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    let (sum2, carry2) = add_with_carry(max_u256, 1);
    assert!(sum2 == 0, 2); // Wraps to 0
    assert!(carry2 == 1, 3); // Carry bit set
}

#[test]
fun test_mul_u128_to_u256() {
    let a: u128 = 1000000000000;
    let b: u128 = 2000000000000;

    let result = mul_u128_to_u256(a, b);
    assert!(result == 2000000000000000000000000, 0);
}

#[test]
fun test_safe_cast_to_u128() {
    let small_value: u256 = 12345;
    let result = safe_cast_to_u128(small_value);
    assert!(result == 12345, 0);

    let max_u128: u256 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    let result2 = safe_cast_to_u128(max_u128);
    assert!(result2 == (max_u128 as u128), 1);
}

#[test]
#[expected_failure(abort_code = EOVERFLOW)]
fun test_safe_cast_overflow() {
    let too_large: u256 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF + 1;
    safe_cast_to_u128(too_large);
}

#[test]
fun test_mul_div_symmetry() {
    // Test that (a * b) / c = (b * a) / c
    let a: u256 = 123456;
    let b: u256 = 789012;
    let c: u256 = 345678;

    let result1 = mul_div(a, b, c);
    let result2 = mul_div(b, a, c);

    assert!(result1 == result2, 0);
}

#[test]
fun test_mul_div_realistic_liquidity_scenario() {
    // Simulate realistic Uniswap v3 calculation
    // liquidity = 10^18, sqrt_price_diff = 10^12
    let liquidity: u256 = 1000000000000000000; // 10^18
    let sqrt_price_diff: u256 = 1000000000000; // 10^12
    let q96: u256 = 79228162514264337593543950336; // 2^96

    // amount = (liquidity * sqrt_price_diff) / 2^96
    let amount = mul_div(liquidity, sqrt_price_diff, q96);

    // Result should be reasonable
    assert!(amount > 0, 0);
    assert!(amount < liquidity, 1); // Should be less than liquidity
}

#[test]
fun test_division_512_by_256_simple() {
    // Test the internal division function with simple case
    // high=0, low=100, denom=10 → result=10
    let result = div_512_by_256(0, 100, 10);
    assert!(result == 10, 0);
}

#[test]
fun test_division_512_by_256_with_high_bits() {
    // Test with high bits set
    // high=1, low=0, denom=2^255 → result=2
    let high: u256 = 1;
    let low: u256 = 0;
    let denom: u256 = 1 << 255; // 2^255

    let result = div_512_by_256(high, low, denom);
    assert!(result == 2, 0);
}
