module nerge_math_lib::math;

use std::debug;
use std::string;

// ==================== Constants ====================

/// Q64.64 fixed point: 2^64
const Q64: u128 = 18446744073709551616;

/// One in E8 format (100,000,000)
const ONE_E8: u128 = 100000000;

/// Get ONE_E8 constant value
public fun one_e8(): u128 {
    ONE_E8
}

/// Maximum u64
const MAX_U64: u64 = 18446744073709551615;

/// Maximum u128
const MAX_U128: u128 = 340282366920938463463374607431768211455;

// ==================== Fixed Point Arithmetic ====================

/// Convert to Q64.64 fixed point
public fun to_q64_64(numerator: u64, denominator: u64): u128 {
    ((numerator as u128) * Q64) / (denominator as u128)
}

/// Convert from Q64.64 to u64
public fun from_q64_64(value: u128): u64 {
    (value / Q64) as u64
}

/// Multiply two Q64.64 numbers
public fun mul_q64_64(a: u128, b: u128): u128 {
    (a * b) / Q64
}

/// Divide two Q64.64 numbers
public fun div_q64_64(a: u128, b: u128): u128 {
    (a * Q64) / b
}

/// Multiply Q64.64 by u64
public fun from_q64_64_mul(fixed: u128, integer: u64): u64 {
    ((fixed * (integer as u128)) / Q64) as u64
}

/// Multiply two values and divide by a third: (a * b) / c
/// Commonly used for fee calculations with fixed-point precision
public fun mul_div(a: u64, b: u128, c: u128): u64 {
    assert!(c > 0, E_DIVISION_BY_ZERO);
    let result = ((a as u128) * b) / c;
    result as u64
}

/// Get Q64.64 scale factor
public fun q64_64_scale(): u128 {
    Q64
}

// ==================== Basic Math ====================

/// Integer square root using Newton's method
public fun sqrt_u64(x: u64): u64 {
    if (x == 0) return 0;
    if (x <= 3) return 1;

    // Initial guess: x/2
    let mut z = x / 2 + 1;
    let mut y = x;

    // Newton's method: z_{n+1} = (z_n + x/z_n) / 2
    while (z < y) {
        y = z;
        z = (x / z + z) / 2;
    };

    y
}

/// Square root for u128
public fun sqrt_u128(x: u128): u128 {
    if (x == 0) return 0;
    if (x <= 3) return 1;

    let mut z = x / 2 + 1;
    let mut y = x;

    while (z < y) {
        y = z;
        z = (x / z + z) / 2;
    };

    y
}

/// Integer power (x^n)
public fun pow_u64(base: u64, exponent: u64): u64 {
    if (exponent == 0) return 1;
    if (base == 0) return 0;

    let mut result = 1u64;
    let mut base_pow = base;
    let mut exp = exponent;

    while (exp > 0) {
        if (exp % 2 == 1) {
            result = result * base_pow;
        };
        base_pow = base_pow * base_pow;
        exp = exp / 2;
    };

    result
}

/// Power for u128
public fun pow_u128(base: u128, exponent: u64): u128 {
    if (exponent == 0) return 1;
    if (base == 0) return 0;

    let mut result = 1u128;
    let mut base_pow = base;
    let mut exp = exponent;

    while (exp > 0) {
        if (exp % 2 == 1) {
            result = result * base_pow;
        };
        base_pow = base_pow * base_pow;
        exp = exp / 2;
    };

    result
}

// ==================== Exponential and Logarithm ====================

/// Natural exponential function e^x (using Taylor series)
/// x should be in E8 format (scaled by 100,000,000)
public fun exp_u128(x: u128): u128 {
    if (x == 0) return ONE_E8;

    // For small x, use Taylor series: e^x = 1 + x + x²/2! + x³/3! + ...
    let mut result = ONE_E8;
    let mut term = ONE_E8;
    let mut i = 1u128;

    // TODO: Calculate up to 20 terms for precision
    while (i <= 11) {
        term = (term * x) / (i * ONE_E8);
        result = result + term;
        if (term < 100) break; // Convergence threshold
        i = i + 1;
    };

    result
}

/// Negative exponential e^(-x)
public fun exp_negative_u128_old(x: u128): u128 {
    let exp_x = exp_u128(x);

    debug::print(&string::utf8(b"=== Exponent Debug Info ==="));
    let result = ONE_E8 * ONE_E8;
    let expo_result = result / exp_x;
    debug::print(&exp_x);
    debug::print(&result);
    debug::print(&expo_result);
    debug::print(&string::utf8(b"=== End ==="));

    (ONE_E8 * ONE_E8) / exp_x
}

/// Negative exponential e^(-x)
public fun exp_negative_u128(x: u128): u128 {
    let exp_x = exp_u128(x);

    debug::print(&string::utf8(b"=== Exponent Debug Info ==="));
    debug::print(&string::utf8(b"exp_x:"));
    debug::print(&exp_x);

    // e^(-x) = 1/e^x
    // In E8 format: ONE_E8 / exp_x
    let result = ONE_E8 / exp_x;

    debug::print(&string::utf8(b"result (1/exp_x):"));
    debug::print(&result);
    debug::print(&string::utf8(b"=== End ==="));

    result
}

/// Natural logarithm ln(x) using Newton's method
/// x should be in E8 format
public fun ln_u128(x: u128): u128 {
    assert!(x > 0, E_INVALID_INPUT);

    if (x == ONE_E8) return 0;

    // Newton's method for ln(x): y = y + (x/e^y - 1)
    let mut y = 0u128;

    // Initial guess based on magnitude
    if (x > ONE_E8) {
        y = ONE_E8;
    };

    // Iterate to converge
    let mut i = 0;
    while (i < 20) {
        let exp_y = exp_u128(y);
        let diff = ((x * ONE_E8) / exp_y);
        if (diff >= ONE_E8 - 1000 && diff <= ONE_E8 + 1000) {
            break
        };
        y = y + diff - ONE_E8;
        i = i + 1;
    };

    y
}

/// Logarithm base 2: log₂(x)
public fun log2_u128(x: u128): u128 {
    let ln_x = ln_u128(x);
    let ln_2 = 69314718; // ln(2) in E8 format
    (ln_x * ONE_E8) / ln_2
}

// ==================== Utility Functions ====================

/// Minimum of two u64 values
public fun min_u64(a: u64, b: u64): u64 {
    if (a < b) { a } else { b }
}

/// Maximum of two u64 values
public fun max_u64(a: u64, b: u64): u64 {
    if (a > b) { a } else { b }
}

/// Minimum of two u128 values
public fun min_u128(a: u128, b: u128): u128 {
    if (a < b) { a } else { b }
}

/// Maximum of two u128 values
public fun max_u128(a: u128, b: u128): u128 {
    if (a > b) { a } else { b }
}

/// Absolute difference between two u64 values
public fun abs_diff_u64(a: u64, b: u64): u64 {
    if (a >= b) { a - b } else { b - a }
}

/// Absolute difference between two u128 values
public fun abs_diff_u128(a: u128, b: u128): u128 {
    if (a >= b) { a - b } else { b - a }
}

/// Multiply with checked overflow
public fun mul_checked(a: u64, b: u64): u64 {
    let result = (a as u128) * (b as u128);
    assert!(result <= (MAX_U64 as u128), E_OVERFLOW);
    result as u64
}

/// Divide with rounding up
public fun div_round_up(a: u64, b: u64): u64 {
    assert!(b > 0, E_DIVISION_BY_ZERO);
    (a + b - 1) / b
}

/// Saturating addition for u64 (returns MAX_U64 on overflow instead of aborting)
public fun saturating_add_u64(a: u64, b: u64): u64 {
    let sum = (a as u128) + (b as u128);
    if (sum > (MAX_U64 as u128)) { MAX_U64 } else { sum as u64 }
}

/// Saturating subtraction for u64 (returns 0 on underflow instead of aborting)
public fun saturating_sub_u64(a: u64, b: u64): u64 {
    if (a > b) { a - b } else { 0 }
}

// ==================== Advanced Q64.64 Operations ====================

/// Get Q64.64 constant for 1.0
public fun one_q64_64(): u128 {
    Q64
}

/// Multiply u64 by Q64.64 and return u64
public fun q64_64_mul_u64(fixed: u128, integer: u64): u64 {
    ((fixed * (integer as u128)) / Q64) as u64
}

/// Multiply two u64 values and return Q64.64
public fun u64_mul_to_q64_64(a: u64, b: u64): u128 {
    (a as u128) * (b as u128)
}

/// Divide two u64 in Q64.64 format
public fun q64_64_div(a: u128, b: u128): u128 {
    assert!(b > 0, E_DIVISION_BY_ZERO);
    ((a as u256) * (Q64 as u256) / (b as u256)) as u128
}

/// Multiply u64 by Q64.64
public fun q64_64_mul(value: u64, multiplier: u128): u64 {
    ((value as u256) * (multiplier as u256) / (Q64 as u256)) as u64
}

/// Multiply u128 by Q64.64 and return u128 (for liquidity calculations)
/// Uses u256 for intermediate calculations to prevent overflow
public fun q64_64_mul_u128(fixed: u128, integer: u128): u128 {
    (((fixed as u256) * (integer as u256)) / (Q64 as u256)) as u128
}

/// Add two Q64.64 numbers
public fun q64_64_add(a: u128, b: u128): u128 {
    a + b
}

/// Subtract two Q64.64 numbers
public fun q64_64_sub(a: u128, b: u128): u128 {
    assert!(a >= b, E_UNDERFLOW);
    a - b
}

/// Convert basis points to Q64.64 (e.g., 5000 bps = 50% = 0.5)
public fun bps_to_q64_64(bps: u64): u128 {
    ((bps as u128) * Q64) / 10000
}

/// Convert Q64.64 to basis points
public fun q64_64_to_bps(value: u128): u64 {
    ((value * 10000) / Q64) as u64
}

// ==================== Statistical Functions ====================

/// Calculate mean of a vector of u64 values
public fun mean_u64(values: &vector<u64>): u64 {
    let len = vector::length(values);
    assert!(len > 0, E_EMPTY_VECTOR);

    let mut sum = 0u128;
    let mut i = 0;

    while (i < len) {
        sum = sum + (*vector::borrow(values, i) as u128);
        i = i + 1;
    };

    (sum / (len as u128)) as u64
}

/// Calculate variance of a vector of u64 values
public fun variance_u64(values: &vector<u64>): u64 {
    let len = vector::length(values);
    assert!(len > 0, E_EMPTY_VECTOR);

    let mean = mean_u64(values);
    let mut sum_squared_diff = 0u128;
    let mut i = 0;

    while (i < len) {
        let value = *vector::borrow(values, i);
        let diff = abs_diff_u64(value, mean);
        sum_squared_diff = sum_squared_diff + ((diff as u128) * (diff as u128));
        i = i + 1;
    };

    (sum_squared_diff / (len as u128)) as u64
}

/// Calculate standard deviation
public fun std_dev_u64(values: &vector<u64>): u64 {
    let variance = variance_u64(values);
    sqrt_u64(variance)
}

/// Calculate weighted average
public fun weighted_average(values: &vector<u64>, weights: &vector<u64>): u64 {
    let len = vector::length(values);
    assert!(len == vector::length(weights), E_LENGTH_MISMATCH);
    assert!(len > 0, E_EMPTY_VECTOR);

    let mut weighted_sum = 0u128;
    let mut total_weight = 0u128;
    let mut i = 0;

    while (i < len) {
        let value = *vector::borrow(values, i) as u128;
        let weight = *vector::borrow(weights, i) as u128;
        weighted_sum = weighted_sum + (value * weight);
        total_weight = total_weight + weight;
        i = i + 1;
    };

    assert!(total_weight > 0, E_ZERO_WEIGHT);
    (weighted_sum / total_weight) as u64
}

/// Calculate median of sorted vector
public fun median_u64(sorted_values: &vector<u64>): u64 {
    let len = vector::length(sorted_values);
    assert!(len > 0, E_EMPTY_VECTOR);

    if (len % 2 == 1) {
        // Odd length: return middle element
        *vector::borrow(sorted_values, len / 2)
    } else {
        // Even length: return average of two middle elements
        let mid1 = *vector::borrow(sorted_values, len / 2 - 1);
        let mid2 = *vector::borrow(sorted_values, len / 2);
        (mid1 + mid2) / 2
    }
}

/// Calculate percentile (e.g., 95 for 95th percentile)
public fun percentile_u64(sorted_values: &vector<u64>, percentile: u64): u64 {
    assert!(percentile <= 100, E_INVALID_PERCENTILE);
    let len = vector::length(sorted_values);
    assert!(len > 0, E_EMPTY_VECTOR);

    let index = ((len as u128) * (percentile as u128) / 100) as u64;
    let index = if (index >= len) { len - 1 } else { index };

    *vector::borrow(sorted_values, index)
}

// ==================== Error Codes ====================

const E_OVERFLOW: u64 = 1000;
const E_UNDERFLOW: u64 = 1001;
const E_DIVISION_BY_ZERO: u64 = 1002;
const E_INVALID_INPUT: u64 = 1003;
const E_EMPTY_VECTOR: u64 = 1004;
const E_LENGTH_MISMATCH: u64 = 1005;
const E_ZERO_WEIGHT: u64 = 1006;
const E_INVALID_PERCENTILE: u64 = 1007;

// ==================== Tick Math ====================

/// Tick offset to map i32 to u32 (2^31)
const TICK_OFFSET: u64 = 8388608; // Half of max tick (16777215), allows tick range [-8388608, +8388607]

/// Calculate tick from Q64.64 price
/// tick = log_1.0001(price)
/// Returns tick + TICK_OFFSET
public fun price_to_tick(price: u128): u32 {
    if (price == 0) return 0; // Should not happen for valid price

    // Convert Q64.64 to E8
    // price_e8 = price * 10^8 / 2^64
    // Use u256 for intermediate multiplication to avoid overflow
    let price_e8 = ((price as u256) * 100000000 / (Q64 as u256)) as u128;

    let is_less_than_one = price_e8 < ONE_E8;

    // If price < 1, use 1/price for log calculation
    let val_for_log = if (is_less_than_one) {
        (ONE_E8 * ONE_E8) / price_e8
    } else {
        price_e8
    };

    // ln(val) in E8
    let ln_val = ln_u128(val_for_log);

    // ln(1.0001) in E8 ~= 9999.5
    // We use 10000 for approximation (log_1.0001(x) ~= ln(x) * 10000)
    // Precise value: ln(1.0001) = 0.00009999500033...
    // In E8: 9999
    let ln_base = 9999;

    // tick_delta = ln_val / ln_base
    // Both are E8, so division yields raw integer ratio
    let tick_delta = (ln_val / ln_base) as u64;

    // Apply sign based on whether price < 1
    if (is_less_than_one) {
        (TICK_OFFSET - tick_delta) as u32
    } else {
        (TICK_OFFSET + tick_delta) as u32
    }
}

/// Calculate sqrt price from tick
/// sqrt_P = sqrt(1.0001^tick) = 1.0001^(tick/2)
/// Uses exp approximation: exp(tick * ln(1.0001) / 2)
public fun tick_to_sqrt_price_old(tick: u32): u128 {
    let (is_negative, abs_tick) = if (tick < (TICK_OFFSET as u32)) {
        (true, (TICK_OFFSET as u32) - tick)
    } else {
        (false, tick - (TICK_OFFSET as u32))
    };

    if (abs_tick == 0) return Q64; // Tick 0 -> Price 1.0

    // ln(1.0001) in E8 ~= 9999.5 -> 10000 approx
    // We want 1.0001^(tick/2) -> exp(tick/2 * ln(1.0001))
    // exponent_e8 = abs_tick * 10000 / 2 = abs_tick * 5000

    // Check for overflow: tick max is ~887272. 887272 * 5000 = 4.4e9. Fits in u64.
    let exponent_e8 = (abs_tick as u128) * 5000; // Using 5000 for ln(1.0001)/2 approx

    let result_e8 = if (is_negative) {
        exp_negative_u128(exponent_e8)
    } else {
        exp_u128(exponent_e8)
    };

    // Convert E8 to Q64.64
    // result_q64 = result_e8 * Q64 / ONE_E8

    debug::print(&string::utf8(b"=== Debug Info ==="));
    debug::print(&tick);
    debug::print(&exponent_e8);
    debug::print(&result_e8);
    debug::print(&string::utf8(b"=== End ==="));

    assert!(((result_e8 * Q64) / ONE_E8) > 0, 111);
    (result_e8 * Q64) / ONE_E8
}

/// Calculate sqrt price from tick
/// sqrt_P = sqrt(1.0001^tick) = 1.0001^(tick/2)
/// Uses exp approximation: exp(tick * ln(1.0001) / 2)
public fun tick_to_sqrt_price_v1(tick: u32): u128 {
    let (is_negative, abs_tick) = if (tick < (TICK_OFFSET as u32)) {
        (true, (TICK_OFFSET as u32) - tick)
    } else {
        (false, tick - (TICK_OFFSET as u32))
    };

    if (abs_tick == 0) return Q64; // Tick 0 -> Price 1.0

    let exponent_e8 = (abs_tick as u128) * 5000;

    let result_e8 = if (is_negative) {
        exp_negative_u128(exponent_e8)
    } else {
        exp_u128(exponent_e8)
    };

    debug::print(&string::utf8(b"=== Debug Info ==="));
    debug::print(&is_negative);
    debug::print(&tick);
    debug::print(&exponent_e8);
    debug::print(&result_e8);
    debug::print(&string::utf8(b"=== End ==="));

    // Convert E8 to Q64.64 using u256 to prevent overflow
    // result_q64 = result_e8 * Q64 / ONE_E8
    let result_q64 = ((result_e8 as u256) * (Q64 as u256) / (ONE_E8 as u256)) as u128;

    assert!(result_q64 > 0, 111);
    result_q64
}

/// Calculate sqrt price from tick using power calculation
public fun tick_to_sqrt_price(tick: u32): u128 {
    let (is_negative, abs_tick) = if (tick < (TICK_OFFSET as u32)) {
        (true, (TICK_OFFSET as u32) - tick)
    } else {
        (false, tick - (TICK_OFFSET as u32))
    };

    if (abs_tick == 0) return Q64;

    // Calculate 1.0001^(tick/2) using repeated squaring
    // This is more efficient and accurate than exp approximation
    let result = pow_1_0001(abs_tick / 2);

    if (is_negative) {
        // Return 1/result in Q64 format
        ((Q64 as u256) * (Q64 as u256) / (result as u256)) as u128
    } else {
        result
    }
}

/// Calculate 1.0001^n using binary exponentiation
fun pow_1_0001(n: u32): u128 {
    let base_e8: u128 = 100010000; // 1.0001 in E8 format

    if (n == 0) return ONE_E8;

    let mut result = ONE_E8;
    let mut base = base_e8;
    let mut exponent = n;

    while (exponent > 0) {
        if (exponent % 2 == 1) {
            result = (result * base) / ONE_E8;
        };
        base = (base * base) / ONE_E8;
        exponent = exponent / 2;
    };

    result
}

// ==================== Swap Math ====================

/// Calculate amount of X needed to move from sqrt_price_a to sqrt_price_b
/// Delta X = L * (1/sqrt_price_lower - 1/sqrt_price_upper)
/// sqrt_price is Q64.64
public fun get_amount_x_delta(
    sqrt_price_a: u128,
    sqrt_price_b: u128,
    liquidity: u128,
    round_up: bool,
): u64 {
    let (sqrt_price_lower, sqrt_price_upper) = if (sqrt_price_a < sqrt_price_b) {
        (sqrt_price_a, sqrt_price_b)
    } else {
        (sqrt_price_b, sqrt_price_a)
    };

    // numerator = liquidity * (sqrt_price_upper - sqrt_price_lower)
    // denominator = sqrt_price_upper * sqrt_price_lower
    // We need to be careful with overflow.
    // liquidity is u128, sqrt_price is u128 (Q64.64).
    // Result should be u64.

    // Using u256 for intermediate calc
    let num = (liquidity as u256) * ((sqrt_price_upper - sqrt_price_lower) as u256) * (Q64 as u256);
    let den = (sqrt_price_upper as u256) * (sqrt_price_lower as u256);

    let result = if (round_up) {
        div_round_up_u256(num, den)
    } else {
        (num / den) as u64
    };

    result
}

/// Calculate amount of Y needed to move from sqrt_price_a to sqrt_price_b
/// Delta Y = L * (sqrt_price_upper - sqrt_price_lower)
public fun get_amount_y_delta(
    sqrt_price_a: u128,
    sqrt_price_b: u128,
    liquidity: u128,
    round_up: bool,
): u64 {
    let (sqrt_price_lower, sqrt_price_upper) = if (sqrt_price_a < sqrt_price_b) {
        (sqrt_price_a, sqrt_price_b)
    } else {
        (sqrt_price_b, sqrt_price_a)
    };

    // result = liquidity * (upper - lower) / Q64
    let diff = sqrt_price_upper - sqrt_price_lower;

    let result = if (round_up) {
        // mul_div_round_up
        let prod = (liquidity as u256) * (diff as u256);
        let q64 = (Q64 as u256);
        ((prod + q64 - 1) / q64) as u64
    } else {
        // Use u256 for safe calculation
        let prod = (liquidity as u256) * (diff as u256);
        let q64 = (Q64 as u256);
        (prod / q64) as u64
    };

    result
}

/// Helper for u256 division rounding up
fun div_round_up_u256(a: u256, b: u256): u64 {
    ((a + b - 1) / b) as u64
}

/// Calculate next sqrt price given an input amount of X
/// We are selling X (price decreases)
/// New P = L * P_current / (L + amount * P_current)
public fun get_next_sqrt_price_from_input_x(
    sqrt_price: u128,
    liquidity: u128,
    amount_in: u64,
): u128 {
    // P_next = (liquidity * sqrt_price) / (liquidity + amount_in * sqrt_price)
    // Be careful with units.
    // amount_in * sqrt_price -> u64 * Q64.64 -> Q64.64 (if we divide by Q64? No)
    // Let's do everything in u256 to be safe.

    let liq = liquidity as u256;
    let price = sqrt_price as u256;
    let amt = amount_in as u256;

    // numerator = liq * price
    let num = liq * price;

    // denominator = liq + (amt * price / Q64)
    // Actually, formula derivation:
    // x_current = L / P
    // x_next = x_current + amount_in = L/P + amount_in
    // P_next = L / x_next = L / (L/P + amount_in) = (L * P) / (L + amount_in * P)
    // Wait, amount_in is raw units. P is Q64.64.
    // x_current is raw units? Yes.
    // L is... ? In Uniswap V3, L is sqrt(x*y).
    // If x is raw, y is raw, L is raw.
    // So L/P -> raw / Q64.64 -> raw * Q64 / Q64.64?
    // x = L / sqrt(P) ? No.
    // x = L / sqrt_P.
    // If L is 1000, sqrt_P is 1.0 (Q64), x = 1000. Correct.

    // So x_next = L/sqrt_P + amount_in.
    // sqrt_P_next = L / x_next = L / (L/sqrt_P + amount_in)
    // = (L * sqrt_P) / (L + amount_in * sqrt_P)

    // Denominator term: amount_in * sqrt_price.
    // Since sqrt_price is Q64.64, this product is effectively shifted by 64 bits.
    // But L is also effectively shifted? No, L is raw.
    // We need to be consistent.
    // If we multiply L by Q64 in the numerator, we get Q64.64 result.

    // num = L * sqrt_P (This is Q64.64 * raw)
    // den = L + (amount_in * sqrt_P / Q64) ? No.
    // Let's look at units.
    // x = L / sqrt_P.
    // If we want x in raw units, and sqrt_P is Q64.64.
    // x = (L << 64) / sqrt_P.

    // x_next = (L << 64) / sqrt_P + amount_in.
    // sqrt_P_next = (L << 64) / x_next
    // = (L << 64) / ((L << 64)/sqrt_P + amount_in)
    // = (L << 64) * sqrt_P / ((L << 64) + amount_in * sqrt_P)

    let l_shifted = liq << 64;
    let product = amt * price;
    let den = l_shifted + product;

    let num = l_shifted * price;

    (num / den) as u128
}

/// Calculate next sqrt price given an input amount of Y
/// We are selling Y (price increases)
/// New P = P_current + amount / L
public fun get_next_sqrt_price_from_input_y(
    sqrt_price: u128,
    liquidity: u128,
    amount_in: u64,
): u128 {
    // y_current = L * sqrt_P
    // y_next = y_current + amount_in
    // sqrt_P_next = y_next / L = (L * sqrt_P + amount_in) / L
    // = sqrt_P + amount_in / L

    // amount_in / L needs to be converted to Q64.64
    // delta_P = (amount_in << 64) / L

    let delta = ((amount_in as u256) << 64) / (liquidity as u256);
    sqrt_price + (delta as u128)
}

// ==================== IL Protection Math ====================

/// Convert sqrt price (Q64.64) to regular price
public fun sqrt_price_to_price(sqrt_price: u128): u128 {
    // Price = (sqrt_price)^2 / 2^64
    let price_u256 = (sqrt_price as u256) * (sqrt_price as u256);
    (price_u256 >> 64) as u128
}

/// Convert regular price to sqrt price (Q64.64)
public fun price_to_sqrt_price(price: u128): u128 {
    // sqrt_price = sqrt(price * 2^64)
    let price_scaled = (price as u256) << 64;
    sqrt_u256(price_scaled) as u128
}

/// Square root of u256 value (for larger calculations)
fun sqrt_u256(value: u256): u256 {
    if (value == 0) return 0;

    // Babylonian method
    let mut x = value;
    let mut y = (x + 1) / 2;

    while (y < x) {
        x = y;
        y = (x + value / x) / 2;
    };

    x
}
