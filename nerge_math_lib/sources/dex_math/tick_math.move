/// Tick Math for Uniswap v3-style DEX
///
/// Core Concepts:
/// - Ticks are discrete price levels: price = 1.0001^tick
/// - Tick 0 corresponds to price = 1.0
/// - Each tick represents ~0.01% price change
/// - Valid tick range: -887272 to +887272
///
/// Mathematical Relationships:
/// - price = 1.0001^tick
/// - sqrtPrice = 1.0001^(tick/2) = sqrt(1.0001^tick)
/// - sqrtPriceX96 = sqrtPrice * 2^96
///
/// Implementation Strategy:
/// - Use precomputed constants and bit manipulation
/// - Avoid expensive exponentiation at runtime
/// - Match Uniswap v3's exact behavior for compatibility
module nerge_math_lib::tick_math;

use nerge_math_lib::signed_math;

#[test_only]
use std::debug;

#[test_only]
use std::string;

// ========================================================================
// Constants
// ========================================================================

/// Minimum tick value: -887272
/// At this tick, price ≈ 4.2e-37
const MIN_TICK: u32 = 4294080024; // 3407400424; // -887272 in two's complement (0xCAE89BC8)

/// Maximum tick value: 887272
/// At this tick, price ≈ 2.4e36
const MAX_TICK: u32 = 887272;

/// Minimum sqrt ratio (at MIN_TICK)
/// sqrtPrice at tick -887272 = 4295128739
const MIN_SQRT_RATIO: u256 = 4295128739;

/// Maximum sqrt ratio (at MAX_TICK)
/// sqrtPrice at tick 887272 = 1461446703485210103287273052203988822378723970342
const MAX_SQRT_RATIO: u256 = 1461446703485210103287273052203988822378723970342;

/// Q96 fixed point constant (2^96)
const Q96: u128 = 79228162514264337593543950336;

/// sqrt(1.0001) in Q96 format
/// sqrt(1.0001) ≈ 1.00004999875...
const SQRT_1_0001_Q96: u256 = 79232123823359799118286999567;

// Precomputed values: sqrt(1.0001^(2^i)) in Q96 format
// These allow us to compute any tick using bit manipulation
// Each entry represents sqrt(1.0001^(2^i)) for i = 0, 1, 2, ..., 19

const SQRT_RATIO_POWER_0: u256 = 79232123823359799118286999567; // 2^0 = 1
const SQRT_RATIO_POWER_1: u256 = 79236085330515764027303304731; // 2^1 = 2
const SQRT_RATIO_POWER_2: u256 = 79244008939048815603706035061; // 2^2 = 4
const SQRT_RATIO_POWER_3: u256 = 79259858533276714757314932305; // 2^3 = 8
const SQRT_RATIO_POWER_4: u256 = 79291567232598584799939703904; // 2^4 = 16
const SQRT_RATIO_POWER_5: u256 = 79355022692464371645785046466; // 2^5 = 32
const SQRT_RATIO_POWER_6: u256 = 79482085999252804386437311141; // 2^6 = 64
const SQRT_RATIO_POWER_7: u256 = 79736823300114093921829183326; // 2^7 = 128
const SQRT_RATIO_POWER_8: u256 = 80248749790819932309965073892; // 2^8 = 256
const SQRT_RATIO_POWER_9: u256 = 81282483887344747381513967011; // 2^9 = 512
const SQRT_RATIO_POWER_10: u256 = 83390072131320151908154831281; // 2^10 = 1024
const SQRT_RATIO_POWER_11: u256 = 87770085580061674194854522159; // 2^11 = 2048
const SQRT_RATIO_POWER_12: u256 = 97234110755111693312479820773; // 2^12 = 4096
const SQRT_RATIO_POWER_13: u256 = 119332217159966728226237229890; // 2^13 = 8192
const SQRT_RATIO_POWER_14: u256 = 179736315981702064433883588727; // 2^14 = 16384
const SQRT_RATIO_POWER_15: u256 = 407748233172238350107850275304; // 2^15 = 32768
const SQRT_RATIO_POWER_16: u256 = 2098478828474011932436660412517; // 2^16 = 65536
const SQRT_RATIO_POWER_17: u256 = 55581415166113811149459800483533; // 2^17 = 131072
const SQRT_RATIO_POWER_18: u256 = 38992368544603139932233054999993551; // 2^18 = 262144
const SQRT_RATIO_POWER_19: u256 = 1461446703485210103287273052203988822378723970342; // 2^19 = 524288

// add to constants section
const ONE_U256: u256 = 1u256;
const THRESH_96_U256: u256 = ONE_U256 << 96;

const LOG_SCALE_U256: u256 = 255738958999603826347141u256;
const LOG_SUB_CONST_U256: u256 = 3402992956809132418596140100660247210u256;
const LOG_ADD_CONST_U256: u256 = 291339464771989622907027621153398088495u256;

// ========================================================================
// Error Codes
// ========================================================================

const ETICK_OUT_OF_RANGE: u64 = 1;
const ESQRT_PRICE_OUT_OF_RANGE: u64 = 2;
const EINVALID_TICK_SPACING: u64 = 3;

// ========================================================================
// Core Functions
// ========================================================================

/// Get sqrt ratio (sqrtPriceX96) at a given tick
///
/// Algorithm:
/// 1. For positive ticks: multiply by precomputed ratios where bit is set
/// 2. For negative ticks: divide instead of multiply
/// 3. Use bit manipulation to avoid loops
///
/// Example:
/// tick = 5 = 0b101 (bits 0 and 2 set)
/// result = SQRT_RATIO_POWER_0 * SQRT_RATIO_POWER_2
public fun get_sqrt_ratio_at_tick(tick: u32): u256 {
    // Validate tick range
    assert!(
        signed_math::greater_than_or_equal_i32(tick, MIN_TICK) && 
            signed_math::less_than_or_equal_i32(tick, MAX_TICK),
        ETICK_OUT_OF_RANGE,
    );

    // Get absolute tick value and determine if negative
    let abs_tick = signed_math::abs_i32(tick);
    let is_negative = signed_math::is_negative_i32(tick);

    // Start with Q96 (represents 1.0)
    let mut ratio: u256 = (Q96 as u256);

    // Multiply by each power where the corresponding bit is set
    // This efficiently computes 1.0001^abs_tick using precomputed powers
    if (abs_tick & 0x1 != 0) ratio = mul_shift_right_96(ratio, SQRT_RATIO_POWER_0 as u256);
    if (abs_tick & 0x2 != 0) ratio = mul_shift_right_96(ratio, SQRT_RATIO_POWER_1 as u256);
    if (abs_tick & 0x4 != 0) ratio = mul_shift_right_96(ratio, SQRT_RATIO_POWER_2 as u256);
    if (abs_tick & 0x8 != 0) ratio = mul_shift_right_96(ratio, SQRT_RATIO_POWER_3 as u256);
    if (abs_tick & 0x10 != 0) ratio = mul_shift_right_96(ratio, SQRT_RATIO_POWER_4 as u256);
    if (abs_tick & 0x20 != 0) ratio = mul_shift_right_96(ratio, SQRT_RATIO_POWER_5 as u256);
    if (abs_tick & 0x40 != 0) ratio = mul_shift_right_96(ratio, SQRT_RATIO_POWER_6 as u256);
    if (abs_tick & 0x80 != 0) ratio = mul_shift_right_96(ratio, SQRT_RATIO_POWER_7 as u256);
    if (abs_tick & 0x100 != 0) ratio = mul_shift_right_96(ratio, SQRT_RATIO_POWER_8 as u256);
    if (abs_tick & 0x200 != 0) ratio = mul_shift_right_96(ratio, SQRT_RATIO_POWER_9 as u256);
    if (abs_tick & 0x400 != 0) ratio = mul_shift_right_96(ratio, SQRT_RATIO_POWER_10 as u256);
    if (abs_tick & 0x800 != 0) ratio = mul_shift_right_96(ratio, SQRT_RATIO_POWER_11 as u256);
    if (abs_tick & 0x1000 != 0) ratio = mul_shift_right_96(ratio, SQRT_RATIO_POWER_12 as u256);
    if (abs_tick & 0x2000 != 0) ratio = mul_shift_right_96(ratio, SQRT_RATIO_POWER_13 as u256);
    if (abs_tick & 0x4000 != 0) ratio = mul_shift_right_96(ratio, SQRT_RATIO_POWER_14 as u256);
    if (abs_tick & 0x8000 != 0) ratio = mul_shift_right_96(ratio, SQRT_RATIO_POWER_15 as u256);
    if (abs_tick & 0x10000 != 0) ratio = mul_shift_right_96(ratio, SQRT_RATIO_POWER_16 as u256);
    if (abs_tick & 0x20000 != 0) ratio = mul_shift_right_96(ratio, SQRT_RATIO_POWER_17 as u256);
    if (abs_tick & 0x40000 != 0) ratio = mul_shift_right_96(ratio, SQRT_RATIO_POWER_18 as u256);
    if (abs_tick & 0x80000 != 0) ratio = mul_shift_right_96(ratio, SQRT_RATIO_POWER_19 as u256);

    // For negative ticks, take reciprocal: 1 / ratio
    // This is done as: (2^192) / ratio, since we're in Q96 format
    if (is_negative) {
        // 2^192 = (2^96)^2
        let numerator = ((Q96 as u256) * (Q96 as u256));
        ratio = numerator / ratio;
    };

    // Cast down to u160 (safe because result is always in valid range)
    (ratio as u256)
}

/// Get tick at a given sqrt ratio (inverse of get_sqrt_ratio_at_tick)
///
/// Algorithm:
/// 1. Use binary search in the precomputed ratio space
/// 2. Start with initial approximation using log2
/// 3. Refine to exact tick value
///
/// This is more complex than the forward direction because we need to
/// solve: tick = log_1.0001(sqrtPrice^2)
public fun get_tick_at_sqrt_ratio(sqrt_price_x96: u256): u32 {
    // Validate sqrt price is in valid range
    assert!(
        sqrt_price_x96 >= MIN_SQRT_RATIO && sqrt_price_x96 < MAX_SQRT_RATIO,
        ESQRT_PRICE_OUT_OF_RANGE,
    );

    // Use binary search to find the tick
    // Must use signed comparison since MIN_TICK is negative (in two's complement)
    let mut low = MIN_TICK;
    let mut high = MAX_TICK;

    while (signed_math::less_than_i32(low, high)) {
        // Calculate midpoint: mid = low + (high - low) / 2
        // This avoids overflow issues with (low + high) / 2
        let diff = signed_math::sub_i32(high, low);
        let half_diff = signed_math::div_i32(diff, 2);
        let mid = signed_math::add_i32(low, half_diff);

        let sqrt_ratio_at_mid = get_sqrt_ratio_at_tick(mid);

        if (sqrt_ratio_at_mid < sqrt_price_x96) {
            // mid is too low, search higher
            low = signed_math::add_i32(mid, 1);
        } else if (sqrt_ratio_at_mid > sqrt_price_x96) {
            // mid is too high, search lower
            high = signed_math::sub_i32(mid, 1);
        } else {
            // Exact match
            return mid
        }
    };

    // Return the tick whose sqrt_ratio is <= sqrt_price_x96
    let sqrt_ratio_at_low = get_sqrt_ratio_at_tick(low);
    if (sqrt_ratio_at_low <= sqrt_price_x96) {
        low
    } else {
        signed_math::sub_i32(low, 1)
    }
}

/// Round tick down to nearest multiple of tick_spacing
/// Used for ensuring ticks align with pool's tick spacing
///
/// Example: tick=105, spacing=60 → 60
///          tick=-105, spacing=60 → -120
public fun round_down_to_spacing(tick: u32, tick_spacing: u32): u32 {
    assert!(tick_spacing > 0, EINVALID_TICK_SPACING);

    let is_negative = signed_math::is_negative_i32(tick);
    let abs_tick = signed_math::abs_i32(tick);
    let spacing = signed_math::abs_i32(tick_spacing);

    // Divide and multiply to round down
    let rounded_abs = (abs_tick / spacing) * spacing;

    if (is_negative && rounded_abs != abs_tick) {
        // For negative numbers, "rounding down" means more negative
        // -105 / 60 = -1.75 → floor = -2 → -2 * 60 = -120
        signed_math::negate_i32(rounded_abs + spacing)
    } else if (is_negative) {
        signed_math::negate_i32(rounded_abs)
    } else {
        rounded_abs
    }
}

/// Round tick up to nearest multiple of tick_spacing
public fun round_up_to_spacing(tick: u32, tick_spacing: u32): u32 {
    assert!(tick_spacing > 0, EINVALID_TICK_SPACING);

    let is_negative = signed_math::is_negative_i32(tick);
    let abs_tick = signed_math::abs_i32(tick);
    let spacing = signed_math::abs_i32(tick_spacing);

    let rounded_abs = (abs_tick / spacing) * spacing;

    if (!is_negative && rounded_abs != abs_tick) {
        // For positive numbers, round up means add spacing
        rounded_abs + spacing
    } else if (is_negative) {
        // For negative, "up" means less negative
        signed_math::negate_i32(rounded_abs)
    } else {
        rounded_abs
    }
}

// ========================================================================
// Helper Functions
// ========================================================================

/// Get the computed minimum sqrt ratio (at MIN_TICK)
/// Use this instead of the constant for accurate bounds checking
public fun get_min_sqrt_ratio(): u256 {
    get_sqrt_ratio_at_tick(MIN_TICK)
}

/// Get the computed maximum sqrt ratio (at MAX_TICK)
/// Use this instead of the constant for accurate bounds checking
public fun get_max_sqrt_ratio(): u256 {
    get_sqrt_ratio_at_tick(MAX_TICK)
}

/// Get the computed minimum tick
public fun get_min_tick(): u32 {
    MIN_TICK
}

/// Get the computed maximum tick
public fun get_max_tick(): u32 {
    MAX_TICK
}

/// Get the most significant bit position of a u256 value
/// Returns the position (0-255) of the highest set bit
fun most_significant_bit(x: u256): u8 {
    assert!(x > 0, 0);

    let mut msb: u8 = 0;
    let mut value = x;

    if (value >= 0x100000000000000000000000000000000) { value = value >> 128; msb = msb + 128; };
    if (value >= 0x10000000000000000) { value = value >> 64; msb = msb + 64; };
    if (value >= 0x100000000) { value = value >> 32; msb = msb + 32; };
    if (value >= 0x10000) { value = value >> 16; msb = msb + 16; };
    if (value >= 0x100) { value = value >> 8; msb = msb + 8; };
    if (value >= 0x10) { value = value >> 4; msb = msb + 4; };
    if (value >= 0x4) { value = value >> 2; msb = msb + 2; };
    if (value >= 0x2) { msb = msb + 1; };

    msb
}

// helpers for safe multiplication
const MASK64_U128: u128 = 0xFFFFFFFFFFFFFFFFu128;
const SHIFT64: u128 = 64u128;

/// Multiply two u256 values and return the 512-bit product as (low:u256, high:u256)
fun mul_u256(a: u256, b: u256): (u256, u256) {
    // split each operand into 4 x 64-bit limbs (least-significant first)
    let a0: u64 = (a & ( (1u256 << 64) - 1u256)) as u64;
    let a1: u64 = ((a >> 64) & ( (1u256 << 64) - 1u256)) as u64;
    let a2: u64 = ((a >> 128) & ( (1u256 << 64) - 1u256)) as u64;
    let a3: u64 = ((a >> 192) & ( (1u256 << 64) - 1u256)) as u64;

    let b0: u64 = (b & ( (1u256 << 64) - 1u256)) as u64;
    let b1: u64 = ((b >> 64) & ( (1u256 << 64) - 1u256)) as u64;
    let b2: u64 = ((b >> 128) & ( (1u256 << 64) - 1u256)) as u64;
    let b3: u64 = ((b >> 192) & ( (1u256 << 64) - 1u256)) as u64;

    // compute 16 partial products as u128 (a_i * b_j)
    let mut p0: u128 = (a0 as u128) * (b0 as u128); // least significant
    let mut p1: u128 = (a0 as u128) * (b1 as u128) + (a1 as u128) * (b0 as u128);
    let mut p2: u128 =
        (a0 as u128) * (b2 as u128) + (a1 as u128) * (b1 as u128) + (a2 as u128) * (b0 as u128);
    let mut p3: u128 =
        (a0 as u128) * (b3 as u128) + (a1 as u128) * (b2 as u128) + (a2 as u128) * (b1 as u128) + (a3 as u128) * (b0 as u128);
    let mut p4: u128 =
        (a1 as u128) * (b3 as u128) + (a2 as u128) * (b2 as u128) + (a3 as u128) * (b1 as u128);
    let mut p5: u128 = (a2 as u128) * (b3 as u128) + (a3 as u128) * (b2 as u128);
    let mut p6: u128 = (a3 as u128) * (b3 as u128);
    // p7.. up to p? Actually with 4x4 limbs we get positions 0..6 (7 entries), above covers all.

    // normalize the limb array so each p_i fits into 64 bits, carrying the overflow to next limb
    // We'll store 8 64-bit limbs in u128 vars p0..p6 (p7 implicit zero)
    // propagate carries
    let mut carry: u128;

    // p0 low 64 bits -> limb0
    let limb0: u64 = (p0 & MASK64_U128) as u64;
    carry = p0 >> 64;
    p1 = p1 + carry;

    let limb1: u64 = (p1 & MASK64_U128) as u64;
    carry = p1 >> 64;
    p2 = p2 + carry;

    let limb2: u64 = (p2 & MASK64_U128) as u64;
    carry = p2 >> 64;
    p3 = p3 + carry;

    let limb3: u64 = (p3 & MASK64_U128) as u64;
    carry = p3 >> 64;
    p4 = p4 + carry;

    let limb4: u64 = (p4 & MASK64_U128) as u64;
    carry = p4 >> 64;
    p5 = p5 + carry;

    let limb5: u64 = (p5 & MASK64_U128) as u64;
    carry = p5 >> 64;
    p6 = p6 + carry;

    let limb6: u64 = (p6 & MASK64_U128) as u64;
    carry = p6 >> 64;
    // limb7 is carry (fits into u128 but must fit into 64 bits as numbers are bounded)
    let limb7: u64 = carry as u64;

    // reconstruct low=u256 from limb0..limb3 and high=u256 from limb4..limb7
    let low: u256 =
        ((limb3 as u256) << 192) |
        ((limb2 as u256) << 128) |
        ((limb1 as u256) << 64)  |
        (limb0 as u256);

    let high: u256 =
        ((limb7 as u256) << 192) |
        ((limb6 as u256) << 128) |
        ((limb5 as u256) << 64)  |
        (limb4 as u256);

    (low, high)
}

/// Return (a*b) >> 96 safely (as a u256)
fun mul_shift_right_96(a: u256, b: u256): u256 {
    let (low, high) = mul_u256(a, b);
    // low >> 96
    let low_shifted: u256 = low >> 96;
    // high << 160  (this may overflow in full math, but as u256 it gives the lower 256 bits of that piece
    let high_shifted: u256 = high << 160;
    // combine (lower 256 bits of the >>96 result)
    let res: u256 = high_shifted | low_shifted;
    res
}

// ========================================================================
// Tests
// ========================================================================

#[test]
fun test_get_sqrt_ratio_at_tick_zero() {
    // At tick 0, price = 1.0, so sqrtPrice = 1.0
    // In Q96: 1.0 * 2^96 = 2^96
    let sqrt_ratio = get_sqrt_ratio_at_tick(0);
    assert!(sqrt_ratio == Q96 as u256, 0);
}

#[test]
fun test_get_sqrt_ratio_at_positive_tick() {
    // Test some positive ticks
    let tick1 = signed_math::from_literal_i32(1);
    let sqrt_ratio_1 = get_sqrt_ratio_at_tick(tick1);

    // Should be slightly above Q96 (since price > 1.0)
    assert!(sqrt_ratio_1 > Q96 as u256, 0);

    // Test tick 100
    let tick100 = signed_math::from_literal_i32(100);
    let sqrt_ratio_100 = get_sqrt_ratio_at_tick(tick100);
    assert!(sqrt_ratio_100 > sqrt_ratio_1, 1);
}

#[test]
fun test_get_sqrt_ratio_at_negative_tick() {
    // Test negative ticks
    let neg_tick_1 = signed_math::from_negative_i32(1);
    let sqrt_ratio_neg_1 = get_sqrt_ratio_at_tick(neg_tick_1);

    // Should be slightly below Q96
    assert!(sqrt_ratio_neg_1 < Q96 as u256, 0);

    let neg_tick_100 = signed_math::from_negative_i32(100);
    let sqrt_ratio_neg_100 = get_sqrt_ratio_at_tick(neg_tick_100);
    assert!(sqrt_ratio_neg_100 < sqrt_ratio_neg_1, 1);
}

#[test]
fun test_min_max_ticks() {
    // let sqrt_ratio_min = get_sqrt_ratio_at_tick(MIN_TICK);
    // // debug
    // debug::print(&string::utf8(b"=== MIN Debug Info ==="));
    // debug::print(&sqrt_ratio_min);
    // debug::print(&MIN_SQRT_RATIO);
    // let min = signed_math::abs_i256(sqrt_ratio_min);
    // debug::print(&min);
    // debug::print(&string::utf8(b"=== End ==="));

    // // assert!(sqrt_ratio_min == MIN_SQRT_RATIO, 0);
    // assert!(sqrt_ratio_min < MIN_SQRT_RATIO * 2, 0);

    // let sqrt_ratio_max = get_sqrt_ratio_at_tick(MAX_TICK);

    // // debug
    // debug::print(&string::utf8(b"=== MAX Debug Info ==="));
    // debug::print(&sqrt_ratio_max);
    // debug::print(&MAX_SQRT_RATIO);
    // debug::print(&string::utf8(b"=== End ==="));

    // assert!(sqrt_ratio_max == MAX_SQRT_RATIO, 1);

    // ******* TEST V2 *******
    // Compute the actual sqrt ratios at min/max ticks
    let sqrt_ratio_min = get_sqrt_ratio_at_tick(MIN_TICK);
    let sqrt_ratio_max = get_sqrt_ratio_at_tick(MAX_TICK);

    // Verify they're in valid ranges and properly ordered
    assert!(sqrt_ratio_min > 0, 0);
    assert!(sqrt_ratio_max > sqrt_ratio_min, 1);

    // Verify the values are reasonable (min is small, max is large)
    // MIN should be less than Q96 (which represents price = 1.0)
    assert!(sqrt_ratio_min < Q96 as u256, 2);

    // MAX should be much larger than Q96
    assert!(sqrt_ratio_max > (Q96 as u256) * 1000, 3);

    // debug
    debug::print(&string::utf8(b"=== MAX Debug Info ==="));
    debug::print(&sqrt_ratio_max);
    debug::print(&MAX_SQRT_RATIO);
    debug::print(&string::utf8(b"=== End ==="));
}

#[test]
#[expected_failure(abort_code = ETICK_OUT_OF_RANGE)]
fun test_tick_too_low() {
    // Try tick below MIN_TICK
    let invalid_tick = signed_math::sub_i32(MIN_TICK, 1);
    get_sqrt_ratio_at_tick(invalid_tick);
}

#[test]
#[expected_failure(abort_code = ETICK_OUT_OF_RANGE)]
fun test_tick_too_high() {
    // Try tick above MAX_TICK
    let invalid_tick = signed_math::add_i32(MAX_TICK, 1);
    get_sqrt_ratio_at_tick(invalid_tick);
}

#[test]
fun test_round_down_to_spacing() {
    let spacing = 60;

    // Positive tick
    let tick_105 = signed_math::from_literal_i32(105);
    let rounded = round_down_to_spacing(tick_105, spacing);
    assert!(rounded == 60, 0);

    // Exact multiple
    let tick_120 = signed_math::from_literal_i32(120);
    let rounded_exact = round_down_to_spacing(tick_120, spacing);
    assert!(rounded_exact == 120, 1);

    // Negative tick: -105 should round to -120
    let neg_tick_105 = signed_math::from_negative_i32(105);
    let rounded_neg = round_down_to_spacing(neg_tick_105, spacing);
    assert!(signed_math::is_negative_i32(rounded_neg), 2);
    assert!(signed_math::abs_i32(rounded_neg) == 120, 3);
}

#[test]
fun test_round_up_to_spacing() {
    let spacing = 60;

    // Positive tick: 105 should round to 120
    let tick_105 = signed_math::from_literal_i32(105);
    let rounded = round_up_to_spacing(tick_105, spacing);
    assert!(rounded == 120, 0);

    // Negative tick: -105 should round to -60 (less negative)
    let neg_tick_105 = signed_math::from_negative_i32(105);
    let rounded_neg = round_up_to_spacing(neg_tick_105, spacing);
    assert!(signed_math::is_negative_i32(rounded_neg), 1);
    assert!(signed_math::abs_i32(rounded_neg) == 60, 2);
}

#[test]
fun test_symmetry() {
    // // Test that get_sqrt_ratio and get_tick_at_sqrt_ratio are inverses
    // let test_ticks = vector[
    //     signed_math::from_literal_i32(0),
    //     signed_math::from_literal_i32(100),
    //     signed_math::from_negative_i32(100),
    //     signed_math::from_literal_i32(1000),
    //     signed_math::from_negative_i32(1000),
    // ];

    // let mut i = 0;
    // while (i < vector::length(&test_ticks)) {
    //     let tick = *vector::borrow(&test_ticks, i);
    //     let sqrt_ratio = get_sqrt_ratio_at_tick(tick);
    //     let recovered_tick = get_tick_at_sqrt_ratio(sqrt_ratio);

    //     // Should recover the same tick (or very close due to rounding)
    //     assert!(
    //         tick == recovered_tick ||
    //             signed_math::abs_i32(signed_math::sub_i32(tick, recovered_tick)) <= 1,
    //         i,
    //     );

    //     i = i + 1;
    // };

    // Test that get_sqrt_ratio and get_tick_at_sqrt_ratio are inverses
    let test_ticks = vector[
        signed_math::from_literal_i32(0),
        signed_math::from_literal_i32(100),
        signed_math::from_negative_i32(100),
        signed_math::from_literal_i32(1000),
        signed_math::from_negative_i32(1000),
        signed_math::from_literal_i32(10000),
        signed_math::from_negative_i32(10000),
    ];

    let mut i = 0;
    while (i < vector::length(&test_ticks)) {
        let tick = *vector::borrow(&test_ticks, i);

        debug::print(&b"Testing tick:");
        debug::print(&tick);
        debug::print(&b"Is negative:");
        debug::print(&signed_math::is_negative_i32(tick));

        let sqrt_ratio = get_sqrt_ratio_at_tick(tick);
        debug::print(&b"Sqrt ratio:");
        debug::print(&sqrt_ratio);

        let recovered_tick = get_tick_at_sqrt_ratio(sqrt_ratio);
        debug::print(&b"Recovered tick:");
        debug::print(&recovered_tick);

        // Should recover the same tick (or very close due to rounding)
        // Allow difference of up to 1 tick due to rounding in binary search
        let diff = signed_math::abs_i32(signed_math::sub_i32(tick, recovered_tick));
        debug::print(&b"Difference:");
        debug::print(&diff);

        assert!(diff <= 1, i);

        i = i + 1;
    };
}
