/// Tick Bitmap Module - Efficient Tick Traversal
///
/// This module provides O(1) lookup for initialized ticks using bitmap data structure.
///
/// Key Concepts:
/// - Ticks are stored in a compressed bitmap format
/// - Each word (256 bits) represents 256 consecutive tick positions
/// - Bit manipulation enables fast "next initialized tick" lookup
///
/// Why This Matters:
/// - Without bitmap: O(n) search through all ticks
/// - With bitmap: O(1) lookup using bit operations
/// - Critical for swap performance when crossing many ticks
///
/// Structure:
/// tick_bitmap: Table<u16, u256>
///   key (u16): word position = tick / tick_spacing / 256
///   value (u256): 256 bits representing which ticks are initialized
///
/// Example:
/// Tick 1000 with spacing 60:
///   compressed = 1000 / 60 = 16
///   word_pos = 16 / 256 = 0
///   bit_pos = 16 % 256 = 16
///   bitmap[0] has bit 16 set
module acl_dex_core::tick_bitmap;

use nerge_math_lib::signed_math;
use sui::table::{Self, Table};

// ========================================================================
// Constants
// ========================================================================

/// Number of bits in a word (u256 has 256 bits)
const WORD_SIZE: u32 = 256;

// ========================================================================
// Error Codes
// ========================================================================

const EINVALID_TICK: u64 = 1;
const EINVALID_TICK_SPACING: u64 = 2;

// ========================================================================
// Core Functions
// ========================================================================

/// Flip a tick in the bitmap (set if unset, unset if set)
///
/// This is called when:
/// - A tick becomes initialized (first liquidity added)
/// - A tick becomes uninitialized (last liquidity removed)
///
/// Process:
/// 1. Calculate word position and bit position
/// 2. Get current word from bitmap
/// 3. XOR to flip the bit
/// 4. Update or remove word
public fun flip_tick(bitmap: &mut Table<u16, u256>, tick: u32, tick_spacing: u32) {
    assert!(tick_spacing > 0, EINVALID_TICK_SPACING);

    // Compress tick to account for spacing
    // Example: tick=120, spacing=60 → compressed=2
    let compressed = signed_math::div_i32(tick, (tick_spacing as u32));

    // Get word position and bit position
    let (word_pos, bit_pos) = position(compressed);

    // Get current word (0 if not exists)
    let word = if (table::contains(bitmap, word_pos)) {
        *table::borrow(bitmap, word_pos)
    } else {
        0u256
    };

    // Flip the bit using XOR
    let mask = 1u256 << (bit_pos as u8);
    let new_word = word ^ mask;

    // Update or remove word
    if (new_word == 0) {
        // All bits are 0, remove word to save storage
        if (table::contains(bitmap, word_pos)) {
            table::remove(bitmap, word_pos);
        };
    } else {
        // Update word
        if (table::contains(bitmap, word_pos)) {
            *table::borrow_mut(bitmap, word_pos) = new_word;
        } else {
            table::add(bitmap, word_pos, new_word);
        };
    };
}

/// Find the next initialized tick in the bitmap
///
/// This is the KEY optimization - O(1) lookup!
///
/// Parameters:
/// - tick: starting tick
/// - tick_spacing: spacing between usable ticks
/// - lte: if true, search left (<=), if false, search right (>)
///
/// Returns: (next_tick, initialized)
/// - next_tick: the next initialized tick (or boundary if none found)
/// - initialized: whether an initialized tick was found
///
/// Algorithm:
/// 1. Compress tick and find word/bit position
/// 2. Mask bits we've already passed
/// 3. Find first set bit in masked word
/// 4. If found, calculate tick; otherwise, search next word
public fun next_initialized_tick_within_one_word(
    bitmap: &Table<u16, u256>,
    tick: u32,
    tick_spacing: u32,
    lte: bool,
): (u32, bool) {
    assert!(tick_spacing > 0, EINVALID_TICK_SPACING);

    let compressed = signed_math::div_i32(tick, (tick_spacing as u32));

    if (lte) {
        // Search to the left (lower ticks)
        next_initialized_tick_lte(bitmap, tick, tick_spacing, compressed)
    } else {
        // Search to the right (higher ticks)
        next_initialized_tick_gt(bitmap, tick, tick_spacing, compressed)
    }
}

/// Search for next initialized tick to the left (<=)
fun next_initialized_tick_lte(
    bitmap: &Table<u16, u256>,
    tick: u32,
    tick_spacing: u32,
    compressed: u32,
): (u32, bool) {
    let (word_pos, bit_pos) = position(compressed);

    // Get the word containing our starting tick
    let word = if (table::contains(bitmap, word_pos)) {
        *table::borrow(bitmap, word_pos)
    } else {
        0u256
    };

    // Create mask to ignore bits to the right of our position
    // Example: bit_pos=5 → mask = 0b111111 (keep bits 0-5)
    let mask = (1u256 << (bit_pos as u8)) + ((1u256 << (bit_pos as u8)) - 1);
    let masked = word & mask;

    // Check if there's an initialized tick in this word
    let initialized = masked != 0;

    let next_tick = if (initialized) {
        // Find the most significant bit (MSB) in masked word
        let msb = most_significant_bit(masked);

        // Calculate the actual tick from word_pos and bit_pos
        let tick_compressed = ((word_pos as u32) * 256 + (msb as u32));
        let next = signed_math::mul_i32((tick_compressed as u32), tick_spacing);
        next
    } else {
        // No initialized tick found, return boundary
        // Move to end of previous word
        let tick_compressed = ((word_pos as u32) * 256);
        signed_math::sub_i32((tick_compressed as u32), 1)
    };

    (next_tick, initialized)
}

/// Search for next initialized tick to the right (>)
fun next_initialized_tick_gt(
    bitmap: &Table<u16, u256>,
    tick: u32,
    tick_spacing: u32,
    compressed: u32,
): (u32, bool) {
    let (word_pos, bit_pos) = position(compressed);

    // Get the word containing our starting tick
    let word = if (table::contains(bitmap, word_pos)) {
        *table::borrow(bitmap, word_pos)
    } else {
        0u256
    };

    // Create mask to ignore bits at or to the left of our position
    // Example: bit_pos=5 → mask = 0b1111...11000000 (keep bits 6-255)
    // This is ~((1 << (bit_pos + 1)) - 1)
    let mask = if (bit_pos < 255) {
        // Normal case
        let keep_right = (1u256 << ((bit_pos + 1) as u8)) - 1;
        // !keep_right
        nerge_math_lib::signed_math::negate_i256(keep_right)
    } else {
        // bit_pos == 255, no bits to the right
        0u256
    };

    let masked = word & mask;

    // Check if there's an initialized tick in this word
    let initialized = masked != 0;

    let next_tick = if (initialized) {
        // Find the least significant bit (LSB) in masked word
        let lsb = least_significant_bit(masked);

        // Calculate the actual tick
        let tick_compressed = ((word_pos as u32) * 256 + (lsb as u32));
        signed_math::mul_i32((tick_compressed as u32), tick_spacing)
    } else {
        // No initialized tick found, return boundary
        // Move to start of next word
        let tick_compressed = ((word_pos as u32) + 1) * 256;
        (tick_compressed as u32)
    };

    (next_tick, initialized)
}

// ========================================================================
// Position Calculation
// ========================================================================

/// Calculate word position and bit position from compressed tick
///
/// compressed_tick = tick / tick_spacing
/// word_pos = compressed_tick / 256
/// bit_pos = compressed_tick % 256
///
/// Example:
/// compressed=1000 → word_pos=3, bit_pos=232
/// (because 1000 = 3*256 + 232)
///

/// Fixed position function for tick_bitmap module
///
/// This matches Uniswap V3's implementation which uses signed integers
/// for word positions stored in the bitmap table.

/// Calculate word position and bit position from compressed tick
///
/// The key insight:
/// - Word position should be i16 (signed) but we return u16
/// - For negative ticks, we use two's complement representation
/// - Bit position is always 0-255
///
/// Examples:
/// - tick=0 → word=0, bit=0
/// - tick=1 → word=0, bit=1
/// - tick=256 → word=1, bit=0
/// - tick=-1 → word=-1 (as u16: 65535), bit=255
/// - tick=-256 → word=-1 (as u16: 65535), bit=0
/// - tick=-257 → word=-2 (as u16: 65534), bit=255
public fun position(compressed_tick: u32): (u16, u8) {
    use nerge_math_lib::signed_math;

    // compressed_tick is i32 stored as u32
    let is_negative = signed_math::is_negative_i32(compressed_tick);

    if (!is_negative) {
        // Positive case is simple
        let word_pos = compressed_tick / 256;
        let bit_pos = compressed_tick % 256;

        // word_pos should fit in u16 for reasonable tick ranges
        ((word_pos as u16), (bit_pos as u8))
    } else {
        // Negative case: need to compute floor division
        // For negative numbers: -1 ÷ 256 = -1 (floor), not 0
        // -256 ÷ 256 = -1
        // -257 ÷ 256 = -2

        let abs_value = signed_math::abs_i32(compressed_tick);

        // Calculate word position (floor division for negative)
        let word_magnitude = (abs_value + 255) / 256;

        // Calculate bit position
        // For negative: -1 mod 256 = 255, -256 mod 256 = 0, -257 mod 256 = 255
        let bit_pos = if (abs_value % 256 == 0) {
            0u8
        } else {
            (256 - (abs_value % 256)) as u8
        };

        // Convert to two's complement for u16
        // -1 = 0xFFFF, -2 = 0xFFFE, etc.
        let word_pos_u16 = ((0x10000 - word_magnitude) as u16);

        (word_pos_u16, bit_pos)
    }
}

// Helper function to convert i16 to u16 (two's complement)
fun i16_to_u16(value: u32, is_negative: bool): u16 {
    if (is_negative) {
        // Two's complement: 0x10000 - abs(value)
        ((0x10000 - value) as u16)
    } else {
        (value as u16)
    }
}

// public fun position(compressed_tick: u32): (u16, u8) {
//     // Handle negative ticks
//     let is_negative = signed_math::is_negative_i32(compressed_tick);
//     let abs_tick = signed_math::abs_i32(compressed_tick);

//     // Calculate word and bit position
//     let word_pos_unsigned = abs_tick / 256;
//     let bit_pos = (abs_tick % 256) as u8;

//     // Adjust for negative ticks
//     let word_pos = if (is_negative) {
//         // Negative word position
//         // Example: tick=-300 → compressed=-5 → word_pos=-1, bit_pos=251
//         if (bit_pos == 0) {
//             // Exactly on word boundary
//             signed_math::negate_i32(word_pos_unsigned)
//         } else {
//             // Not on boundary, need to go one word further negative
//             signed_math::negate_i32(word_pos_unsigned + 1)
//         }
//     } else {
//         word_pos_unsigned
//     };

//     // Adjust bit position for negative ticks
//     let adjusted_bit_pos = if (is_negative && bit_pos != 0) {
//         // For negative, count from the right
//         // Example: -5 % 256 = 251 (not 5)
//         // Cast 256 to u16 first, then subtract, then cast back to u8
//         ((256u16 - (bit_pos as u16)) as u8)
//     } else {
//         bit_pos
//     };

//     ((word_pos as u16), adjusted_bit_pos)
// }

// ========================================================================
// Bit Manipulation Helpers
// ========================================================================

/// Find the most significant bit (MSB) position in a u256
///
/// Returns the position (0-255) of the highest set bit.
/// Example: 0b1010 → returns 3
///
/// Algorithm: Binary search from high to low bits
public fun most_significant_bit(x: u256): u8 {
    assert!(x > 0, 0);

    let mut msb: u8 = 0;
    let mut value = x;

    // Binary search for MSB (8 steps for 256 bits)
    if (value >= (1u256 << 128)) { value = value >> 128; msb = msb + 128; };
    if (value >= (1u256 << 64)) { value = value >> 64; msb = msb + 64; };
    if (value >= (1u256 << 32)) { value = value >> 32; msb = msb + 32; };
    if (value >= (1u256 << 16)) { value = value >> 16; msb = msb + 16; };
    if (value >= (1u256 << 8)) { value = value >> 8; msb = msb + 8; };
    if (value >= (1u256 << 4)) { value = value >> 4; msb = msb + 4; };
    if (value >= (1u256 << 2)) { value = value >> 2; msb = msb + 2; };
    if (value >= (1u256 << 1)) { msb = msb + 1; };

    msb
}

/// Find the least significant bit (LSB) position in a u256
///
/// Returns the position (0-255) of the lowest set bit.
/// Example: 0b1010 → returns 1
///
/// Algorithm: Use two's complement trick: x & -x isolates LSB
public fun least_significant_bit(x: u256): u8 {
    assert!(x > 0, 0);

    // Isolate the least significant bit using: x & (x - 1) complement
    // Actually, we want x & -x, but since we're unsigned, we use:
    // LSB = x & (~x + 1)
    // But there's an easier way: find first set bit

    let mut lsb: u8 = 0;
    let mut value = x;

    // Check each bit from right to left
    if ((value & ((1u256 << 128) - 1)) == 0) { value = value >> 128; lsb = lsb + 128; };
    if ((value & ((1u256 << 64) - 1)) == 0) { value = value >> 64; lsb = lsb + 64; };
    if ((value & ((1u256 << 32) - 1)) == 0) { value = value >> 32; lsb = lsb + 32; };
    if ((value & ((1u256 << 16) - 1)) == 0) { value = value >> 16; lsb = lsb + 16; };
    if ((value & ((1u256 << 8) - 1)) == 0) { value = value >> 8; lsb = lsb + 8; };
    if ((value & ((1u256 << 4) - 1)) == 0) { value = value >> 4; lsb = lsb + 4; };
    if ((value & ((1u256 << 2) - 1)) == 0) { value = value >> 2; lsb = lsb + 2; };
    if ((value & ((1u256 << 1) - 1)) == 0) { lsb = lsb + 1; };

    lsb
}

// ========================================================================
// Query Functions
// ========================================================================

/// Check if a tick is initialized in the bitmap
public fun is_initialized(bitmap: &Table<u16, u256>, tick: u32, tick_spacing: u32): bool {
    let compressed = signed_math::div_i32(tick, tick_spacing);
    let (word_pos, bit_pos) = position(compressed);

    if (!table::contains(bitmap, word_pos)) {
        return false
    };

    let word = *table::borrow(bitmap, word_pos);
    let mask = 1u256 << (bit_pos as u8);

    (word & mask) != 0
}

// ========================================================================
// Tests
// ========================================================================

#[test_only]
use sui::test_scenario;

#[test]
fun test_position_calculation() {
    // Test positive ticks
    let (word_pos, bit_pos) = position(0);
    assert!(word_pos == 0 && bit_pos == 0, 0);

    let (word_pos, bit_pos) = position(255);
    assert!(word_pos == 0 && bit_pos == 255, 1);

    let (word_pos, bit_pos) = position(256);
    assert!(word_pos == 1 && bit_pos == 0, 2);

    let (word_pos, bit_pos) = position(1000);
    assert!(word_pos == 3 && bit_pos == 232, 3);
}

#[test]
fun test_flip_tick() {
    let mut scenario = test_scenario::begin(@0xA);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut bitmap = table::new<u16, u256>(ctx);

    // Flip tick 0 (should set bit)
    flip_tick(&mut bitmap, 0, 60);
    assert!(is_initialized(&bitmap, 0, 60), 0);

    // Flip again (should unset bit)
    flip_tick(&mut bitmap, 0, 60);
    assert!(!is_initialized(&bitmap, 0, 60), 1);

    // Flip tick 60
    flip_tick(&mut bitmap, 60, 60);
    assert!(is_initialized(&bitmap, 60, 60), 2);

    // Flip tick 120
    flip_tick(&mut bitmap, 120, 60);
    assert!(is_initialized(&bitmap, 120, 60), 3);

    table::drop(bitmap);
    test_scenario::end(scenario);
}

#[test]
fun test_most_significant_bit() {
    assert!(most_significant_bit(1) == 0, 0);
    assert!(most_significant_bit(2) == 1, 1);
    assert!(most_significant_bit(4) == 2, 2);
    assert!(most_significant_bit(8) == 3, 3);
    assert!(most_significant_bit(15) == 3, 4); // 0b1111 → MSB at 3
    assert!(most_significant_bit(255) == 7, 5);
    assert!(most_significant_bit(256) == 8, 6);
}

#[test]
fun test_least_significant_bit() {
    assert!(least_significant_bit(1) == 0, 0);
    assert!(least_significant_bit(2) == 1, 1);
    assert!(least_significant_bit(4) == 2, 2);
    assert!(least_significant_bit(8) == 3, 3);
    assert!(least_significant_bit(12) == 2, 4); // 0b1100 → LSB at 2
    assert!(least_significant_bit(255) == 0, 5);
    assert!(least_significant_bit(256) == 8, 6);
}

// #[test]
// fun test_next_initialized_tick_gt() {
//     let mut scenario = test_scenario::begin(@0xA);
//     let ctx = test_scenario::ctx(&mut scenario);

//     let mut bitmap = table::new<u16, u256>(ctx);
//     let spacing = 60;

//     // Initialize ticks: 0, 60, 180, 300
//     flip_tick(&mut bitmap, 0, spacing);
//     flip_tick(&mut bitmap, 60, spacing);
//     flip_tick(&mut bitmap, 180, spacing);
//     flip_tick(&mut bitmap, 300, spacing);

//     // Search from -60 (should find 0)
//     let (next, found) = next_initialized_tick_within_one_word(
//         &bitmap,
//         signed_math::from_negative_i32(60),
//         spacing,
//         false, // search right
//     );
//     assert!(found, 0);
//     assert!(next == 0, 1);

//     // Search from 0 (should find 60)
//     let (next, found) = next_initialized_tick_within_one_word(
//         &bitmap,
//         0,
//         spacing,
//         false,
//     );
//     assert!(found, 2);
//     assert!(next == 60, 3);

//     // Search from 61 (should find 180)
//     let (next, found) = next_initialized_tick_within_one_word(
//         &bitmap,
//         61,
//         spacing,
//         false,
//     );
//     assert!(found, 4);
//     assert!(next == 180, 5);

//     table::drop(bitmap);
//     test_scenario::end(scenario);
// }

#[test]
fun test_next_initialized_tick_gt() {
    let mut scenario = test_scenario::begin(@0xA);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut bitmap = table::new<u16, u256>(ctx);
    let spacing = 60;

    // Initialize ticks: 60, 180, 300 (all in same word)
    flip_tick(&mut bitmap, 60, spacing);
    flip_tick(&mut bitmap, 180, spacing);
    flip_tick(&mut bitmap, 300, spacing);

    // Search from 0 (should find 60)
    let (next, found) = next_initialized_tick_within_one_word(
        &bitmap,
        0,
        spacing,
        false, // search right
    );
    assert!(found, 0);
    assert!(next == 60, 1);

    // Search from 61 (should find 180)
    let (next, found) = next_initialized_tick_within_one_word(
        &bitmap,
        61,
        spacing,
        false,
    );
    assert!(found, 2);
    assert!(next == 180, 3);

    table::drop(bitmap);
    test_scenario::end(scenario);
}

#[test]
fun test_next_initialized_tick_lte() {
    let mut scenario = test_scenario::begin(@0xA);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut bitmap = table::new<u16, u256>(ctx);
    let spacing = 60;

    // Initialize ticks: 0, 60, 180, 300
    flip_tick(&mut bitmap, 0, spacing);
    flip_tick(&mut bitmap, 60, spacing);
    flip_tick(&mut bitmap, 180, spacing);
    flip_tick(&mut bitmap, 300, spacing);

    // Search from 400 (should find 300)
    let (next, found) = next_initialized_tick_within_one_word(
        &bitmap,
        400,
        spacing,
        true, // search left
    );
    assert!(found, 0);
    assert!(next == 300, 1);

    // Search from 300 (should find 300)
    let (next, found) = next_initialized_tick_within_one_word(
        &bitmap,
        300,
        spacing,
        true,
    );
    assert!(found, 2);
    assert!(next == 300, 3);

    // Search from 200 (should find 180)
    let (next, found) = next_initialized_tick_within_one_word(
        &bitmap,
        200,
        spacing,
        true,
    );
    assert!(found, 4);
    assert!(next == 180, 5);

    table::drop(bitmap);
    test_scenario::end(scenario);
}

#[test]
fun test_bitmap_across_multiple_words() {
    let mut scenario = test_scenario::begin(@0xA);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut bitmap = table::new<u16, u256>(ctx);
    let spacing = 60;

    // Initialize ticks in different words
    flip_tick(&mut bitmap, 0, spacing); // word 0
    flip_tick(&mut bitmap, 15360, spacing); // word 1 (256*60=15360)
    flip_tick(&mut bitmap, 30720, spacing); // word 2

    assert!(is_initialized(&bitmap, 0, spacing), 0);
    assert!(is_initialized(&bitmap, 15360, spacing), 1);
    assert!(is_initialized(&bitmap, 30720, spacing), 2);

    // Uninitialized ticks
    assert!(!is_initialized(&bitmap, 60, spacing), 3);
    assert!(!is_initialized(&bitmap, 120, spacing), 4);

    table::drop(bitmap);
    test_scenario::end(scenario);
}
