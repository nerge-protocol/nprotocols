module p2ph_lending_core::interest_rate;

use nerge_math_lib::math;

// ==================== Constants ====================

const SECONDS_PER_YEAR: u64 = 31536000;

// ==================== Core Functions ====================

/// Calculate borrow rate using kinked model
/// Returns rate per second in basis points
public fun calculate_borrow_rate(
    utilization: u64, // In basis points (0-10000)
    base_rate: u64,
    multiplier: u64,
    jump_multiplier: u64,
    optimal_util: u64,
): u64 {
    if (utilization <= optimal_util) {
        // Below kink: linear increase
        base_rate + (utilization * multiplier) / 10000
    } else {
        // Above kink: steep increase
        let normal_rate = base_rate + (optimal_util * multiplier) / 10000;
        let excess_util = utilization - optimal_util;
        normal_rate + (excess_util * jump_multiplier) / 10000
    }
}

/// Calculate supply rate from borrow rate
public fun calculate_supply_rate(borrow_rate: u64, utilization: u64, reserve_factor: u64): u64 {
    let rate_to_pool = (borrow_rate * (10000 - reserve_factor)) / 10000;
    (rate_to_pool * utilization) / 10000
}

/// Convert annual rate to per-second rate
public fun annual_to_per_second(annual_rate: u64): u64 {
    annual_rate / SECONDS_PER_YEAR
}

/// Convert per-second rate to annual rate
public fun per_second_to_annual(per_second_rate: u64): u64 {
    per_second_rate * SECONDS_PER_YEAR
}
