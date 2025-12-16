module nerge_oracle::twap;

use nerge_math_lib::math;
use std::vector;
use sui::clock::{Self, Clock};
use sui::object::{Self, UID};
use sui::tx_context::TxContext;

// ==================== Structs ====================

/// Time-weighted average price accumulator
public struct TWAPAccumulator has store {
    /// Cumulative price * time
    cumulative_price: u128,
    /// Last observation price (Q64.64)
    last_price: u128,
    /// Last observation timestamp
    last_timestamp: u64,
    /// Observation history (limited window)
    observations: vector<PriceObservation>,
    /// Maximum observations to keep
    max_observations: u64,
}

/// Individual price observation
public struct PriceObservation has copy, drop, store {
    price: u128,
    timestamp: u64,
    cumulative: u128,
}

// ==================== Core Functions ====================

/// Create new TWAP accumulator
public fun new_accumulator(
    initial_price: u128,
    timestamp: u64,
    max_observations: u64,
): TWAPAccumulator {
    TWAPAccumulator {
        cumulative_price: 0,
        last_price: initial_price,
        last_timestamp: timestamp,
        observations: vector::empty(),
        max_observations,
    }
}

/// Update TWAP with new price observation
public fun update(accumulator: &mut TWAPAccumulator, new_price: u128, clock: &Clock) {
    let current_time = clock::timestamp_ms(clock);
    let time_elapsed = current_time - accumulator.last_timestamp;

    if (time_elapsed > 0) {
        // Accumulate: cumulative += last_price * time_elapsed
        let price_time = accumulator.last_price * (time_elapsed as u128);
        accumulator.cumulative_price = accumulator.cumulative_price + price_time;

        // Add observation
        let observation = PriceObservation {
            price: new_price,
            timestamp: current_time,
            cumulative: accumulator.cumulative_price,
        };

        vector::push_back(&mut accumulator.observations, observation);

        // Remove old observations if exceeding max
        while (vector::length(&accumulator.observations) > accumulator.max_observations) {
            vector::remove(&mut accumulator.observations, 0);
        };

        accumulator.last_price = new_price;
        accumulator.last_timestamp = current_time;
    };
}

/// Get TWAP over specified duration
public fun get_twap(accumulator: &TWAPAccumulator, duration_ms: u64, clock: &Clock): u128 {
    let current_time = clock::timestamp_ms(clock);
    let target_time = current_time - duration_ms;

    // Find observation closest to target time
    let len = vector::length(&accumulator.observations);
    if (len == 0) {
        return accumulator.last_price
    };

    let mut i = 0;
    while (i < len) {
        let obs = vector::borrow(&accumulator.observations, i);
        if (obs.timestamp >= target_time) {
            break
        };
        i = i + 1;
    };

    if (i >= len) {
        // All observations are before target time
        return accumulator.last_price
    };

    let start_obs = vector::borrow(&accumulator.observations, i);
    let price_delta = accumulator.cumulative_price - start_obs.cumulative;
    let time_delta = current_time - start_obs.timestamp;

    if (time_delta == 0) {
        accumulator.last_price
    } else {
        price_delta / (time_delta as u128)
    }
}

/// Get current spot price
public fun get_spot_price(accumulator: &TWAPAccumulator): u128 {
    accumulator.last_price
}
