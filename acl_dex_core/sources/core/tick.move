/// Tick Module - Manages tick state and liquidity tracking
///
/// Handles:
/// - Tick initialization and updates
/// - Liquidity net calculations (signed arithmetic)
/// - Fee growth tracking outside tick ranges
/// - Tick crossing logic
/// - Bitmap integration for efficient tick traversal
module acl_dex_core::tick;

use acl_dex_core::tick_bitmap;
use nerge_math_lib::signed_math;
use sui::table::{Self, Table};

// ========================================================================
// Error Codes
// ========================================================================

const ETICK_NOT_FOUND: u64 = 1;
const EINSUFFICIENT_LIQUIDITY: u64 = 2;

// ========================================================================
// Structs
// ========================================================================

/// Per-tick state
public struct TickInfo has copy, drop, store {
    /// Total liquidity referencing this tick
    liquidity_gross: u128,
    /// Net liquidity change when crossing this tick
    /// Positive when entering range from below, negative from above
    liquidity_net: u128,
    is_liquidity_net_negative: bool,
    /// Fee growth outside this tick
    fee_growth_outside_0_x128: u256,
    fee_growth_outside_1_x128: u256,
    /// Whether this tick is initialized (has liquidity)
    initialized: bool,
}

/// Container for all ticks in a pool
public struct TickManager has store {
    ticks: Table<u32, TickInfo>,
    tick_bitmap: Table<u16, u256>,
}

// ========================================================================
// Constructor
// ========================================================================

/// Create a new tick manager
public fun new(ctx: &mut sui::tx_context::TxContext): TickManager {
    TickManager {
        ticks: table::new(ctx),
        tick_bitmap: table::new(ctx),
    }
}

// ========================================================================
// Tick Info Access
// ========================================================================

/// Check if a tick is initialized
public fun is_initialized(manager: &TickManager, tick: u32): bool {
    if (!table::contains(&manager.ticks, tick)) {
        return false
    };
    table::borrow(&manager.ticks, tick).initialized
}

/// Check if a tick exists in the table
public fun contains(manager: &TickManager, tick: u32): bool {
    table::contains(&manager.ticks, tick)
}

/// Get tick info (returns default values if tick doesn't exist)
public fun get_info(manager: &TickManager, tick: u32): (u128, u128, bool, u256, u256, bool) {
    if (!table::contains(&manager.ticks, tick)) {
        return (0, 0, false, 0, 0, false)
    };

    let info = table::borrow(&manager.ticks, tick);
    (
        info.liquidity_gross,
        info.liquidity_net,
        info.is_liquidity_net_negative,
        info.fee_growth_outside_0_x128,
        info.fee_growth_outside_1_x128,
        info.initialized,
    )
}

/// Get tick info reference (must exist)
public fun get(manager: &TickManager, tick: u32): &TickInfo {
    assert!(table::contains(&manager.ticks, tick), ETICK_NOT_FOUND);
    table::borrow(&manager.ticks, tick)
}

/// Get mutable tick info reference (must exist)
public fun get_mut(manager: &mut TickManager, tick: u32): &mut TickInfo {
    assert!(table::contains(&manager.ticks, tick), ETICK_NOT_FOUND);
    table::borrow_mut(&mut manager.ticks, tick)
}

// ========================================================================
// TickInfo Accessors
// ========================================================================

public fun liquidity_gross(info: &TickInfo): u128 {
    info.liquidity_gross
}

public fun liquidity_net(info: &TickInfo): u128 {
    info.liquidity_net
}

public fun is_liquidity_net_negative(info: &TickInfo): bool {
    info.is_liquidity_net_negative
}

public fun fee_growth_outside_0(info: &TickInfo): u256 {
    info.fee_growth_outside_0_x128
}

public fun fee_growth_outside_1(info: &TickInfo): u256 {
    info.fee_growth_outside_1_x128
}

public fun initialized(info: &TickInfo): bool {
    info.initialized
}

// ========================================================================
// Tick Updates
// ========================================================================

/// Update a tick when adding liquidity (mint)
///
/// Parameters:
/// - manager: The tick manager
/// - tick: The tick to update
/// - liquidity_delta: Amount of liquidity to add
/// - upper: Whether this is the upper tick of the range
/// - current_tick: Current pool tick (for fee growth initialization)
/// - fee_growth_global_0: Global fee growth for token0
/// - fee_growth_global_1: Global fee growth for token1
/// - tick_spacing: Tick spacing for bitmap operations
///
/// Returns: Whether the tick was flipped (initialized or uninitialized)
public fun update_for_mint(
    manager: &mut TickManager,
    tick: u32,
    liquidity_delta: u128,
    upper: bool,
    current_tick: u32,
    fee_growth_global_0: u256,
    fee_growth_global_1: u256,
    tick_spacing: u32,
): bool {
    // Get or create tick info
    if (!table::contains(&manager.ticks, tick)) {
        table::add(
            &mut manager.ticks,
            tick,
            TickInfo {
                liquidity_gross: 0,
                liquidity_net: 0,
                is_liquidity_net_negative: false,
                fee_growth_outside_0_x128: 0,
                fee_growth_outside_1_x128: 0,
                initialized: false,
            },
        );
    };

    let info = table::borrow_mut(&mut manager.ticks, tick);
    let liquidity_gross_before = info.liquidity_gross;

    // Update liquidity_gross
    info.liquidity_gross = liquidity_gross_before + liquidity_delta;

    // Update liquidity_net
    // Lower tick: add liquidity (entered from below)
    // Upper tick: subtract liquidity (exited from below)
    if (upper) {
        let (new_net, is_negative) = subtract_liquidity_net(
            info.liquidity_net,
            info.is_liquidity_net_negative,
            liquidity_delta,
        );
        info.liquidity_net = new_net;
        info.is_liquidity_net_negative = is_negative;
    } else {
        let (new_net, is_negative) = add_liquidity_net(
            info.liquidity_net,
            info.is_liquidity_net_negative,
            liquidity_delta,
        );
        info.liquidity_net = new_net;
        info.is_liquidity_net_negative = is_negative;
    };

    // Check if tick was flipped
    let flipped = (liquidity_gross_before == 0) && (info.liquidity_gross > 0);

    if (flipped) {
        // Tick is being initialized
        info.initialized = true;

        // Initialize fee growth outside
        // If current tick >= this tick, initialize to current global
        if (signed_math::greater_than_or_equal_i32(current_tick, tick)) {
            info.fee_growth_outside_0_x128 = fee_growth_global_0;
            info.fee_growth_outside_1_x128 = fee_growth_global_1;
        };
        // Otherwise keep as 0 (default)

        // Flip the bit in the bitmap
        tick_bitmap::flip_tick(&mut manager.tick_bitmap, tick, tick_spacing);
    };

    flipped
}

/// Update a tick when removing liquidity (burn)
///
/// Parameters:
/// - manager: The tick manager
/// - tick: The tick to update
/// - liquidity_delta: Amount of liquidity to remove
/// - upper: Whether this is the upper tick of the range
/// - tick_spacing: Tick spacing for bitmap operations
///
/// Returns: Whether the tick was flipped (uninitialized)
public fun update_for_burn(
    manager: &mut TickManager,
    tick: u32,
    liquidity_delta: u128,
    upper: bool,
    tick_spacing: u32,
): bool {
    assert!(table::contains(&manager.ticks, tick), ETICK_NOT_FOUND);

    let info = table::borrow_mut(&mut manager.ticks, tick);
    let liquidity_gross_before = info.liquidity_gross;

    // Decrease liquidity_gross
    assert!(liquidity_gross_before >= liquidity_delta, EINSUFFICIENT_LIQUIDITY);
    info.liquidity_gross = liquidity_gross_before - liquidity_delta;

    // Update liquidity_net (opposite of mint)
    if (upper) {
        // For upper tick, add back (opposite of subtract in mint)
        let (new_net, is_negative) = add_liquidity_net(
            info.liquidity_net,
            info.is_liquidity_net_negative,
            liquidity_delta,
        );
        info.liquidity_net = new_net;
        info.is_liquidity_net_negative = is_negative;
    } else {
        // For lower tick, subtract (opposite of add in mint)
        let (new_net, is_negative) = subtract_liquidity_net(
            info.liquidity_net,
            info.is_liquidity_net_negative,
            liquidity_delta,
        );
        info.liquidity_net = new_net;
        info.is_liquidity_net_negative = is_negative;
    };

    // Check if tick should be uninitialized
    let flipped = (liquidity_gross_before != 0) && (info.liquidity_gross == 0);

    if (flipped) {
        info.initialized = false;
        // Flip the bit in the bitmap
        tick_bitmap::flip_tick(&mut manager.tick_bitmap, tick, tick_spacing);
    };

    flipped
}

/// Cross a tick during a swap
/// Updates fee growth outside and returns liquidity change
///
/// Returns: (liquidity_net, is_negative)
public fun cross(
    manager: &mut TickManager,
    tick: u32,
    fee_growth_global_0: u256,
    fee_growth_global_1: u256,
): (u128, bool) {
    let info = table::borrow_mut(&mut manager.ticks, tick);

    // Update fee growth outside this tick
    info.fee_growth_outside_0_x128 = fee_growth_global_0 - info.fee_growth_outside_0_x128;
    info.fee_growth_outside_1_x128 = fee_growth_global_1 - info.fee_growth_outside_1_x128;

    // Return liquidity_net to apply to active liquidity
    (info.liquidity_net, info.is_liquidity_net_negative)
}

// ========================================================================
// Fee Growth Calculations
// ========================================================================

/// Get fee growth inside a tick range
///
/// Formula:
/// fee_inside = fee_global - fee_below_lower - fee_above_upper
///
/// Returns: (fee_growth_inside_0, fee_growth_inside_1)
public fun get_fee_growth_inside(
    manager: &TickManager,
    tick_lower: u32,
    tick_upper: u32,
    current_tick: u32,
    fee_growth_global_0: u256,
    fee_growth_global_1: u256,
): (u256, u256) {
    // Get fee growth below lower tick
    let (fee_growth_below_0, fee_growth_below_1) = if (
        table::contains(&manager.ticks, tick_lower)
    ) {
        let lower = table::borrow(&manager.ticks, tick_lower);
        if (signed_math::greater_than_or_equal_i32(current_tick, tick_lower)) {
            // Current tick >= lower tick: fees below = fee_outside
            (lower.fee_growth_outside_0_x128, lower.fee_growth_outside_1_x128)
        } else {
            // Current tick < lower tick: fees below = global - fee_outside
            (
                fee_growth_global_0 - lower.fee_growth_outside_0_x128,
                fee_growth_global_1 - lower.fee_growth_outside_1_x128,
            )
        }
    } else {
        (0, 0)
    };

    // Get fee growth above upper tick
    let (fee_growth_above_0, fee_growth_above_1) = if (
        table::contains(&manager.ticks, tick_upper)
    ) {
        let upper = table::borrow(&manager.ticks, tick_upper);
        if (signed_math::less_than_i32(current_tick, tick_upper)) {
            // Current tick < upper tick: fees above = fee_outside
            (upper.fee_growth_outside_0_x128, upper.fee_growth_outside_1_x128)
        } else {
            // Current tick >= upper tick: fees above = global - fee_outside
            (
                fee_growth_global_0 - upper.fee_growth_outside_0_x128,
                fee_growth_global_1 - upper.fee_growth_outside_1_x128,
            )
        }
    } else {
        (0, 0)
    };

    // Calculate fee growth inside the range
    let fee_growth_inside_0 = fee_growth_global_0 - fee_growth_below_0 - fee_growth_above_0;
    let fee_growth_inside_1 = fee_growth_global_1 - fee_growth_below_1 - fee_growth_above_1;

    (fee_growth_inside_0, fee_growth_inside_1)
}

// ========================================================================
// Signed Arithmetic Helpers
// ========================================================================

/// Add to liquidity_net (signed arithmetic)
fun add_liquidity_net(current: u128, is_negative: bool, delta: u128): (u128, bool) {
    if (is_negative) {
        // Current is negative
        if (delta >= current) {
            // Result is positive
            (delta - current, false)
        } else {
            // Result is still negative
            (current - delta, true)
        }
    } else {
        // Current is positive, add delta
        (current + delta, false)
    }
}

/// Subtract from liquidity_net (signed arithmetic)
fun subtract_liquidity_net(current: u128, is_negative: bool, delta: u128): (u128, bool) {
    if (is_negative) {
        // Current is negative, subtracting makes it more negative
        (current + delta, true)
    } else {
        // Current is positive
        if (current >= delta) {
            // Result is still positive
            (current - delta, false)
        } else {
            // Result becomes negative
            (delta - current, true)
        }
    }
}

// ========================================================================
// Tick Navigation (using bitmap for O(1) lookup)
// ========================================================================

/// Find next initialized tick using the bitmap
///
/// This is the optimized version that uses bitmap for O(1) lookup
/// instead of linear search.
///
/// Parameters:
/// - tick: Current tick position
/// - tick_spacing: Tick spacing
/// - lte: If true, search left (<=), if false, search right (>)
///
/// Returns: (next_tick, initialized)
public fun next_initialized_tick_within_one_word(
    manager: &TickManager,
    tick: u32,
    tick_spacing: u32,
    lte: bool,
): (u32, bool) {
    tick_bitmap::next_initialized_tick_within_one_word(
        &manager.tick_bitmap,
        tick,
        tick_spacing,
        lte,
    )
}

// ========================================================================
// Destroy
// ========================================================================

/// Drop the tick manager (for testing)
public fun drop(manager: TickManager) {
    let TickManager { ticks, tick_bitmap } = manager;
    table::drop(ticks);
    table::drop(tick_bitmap);
}
