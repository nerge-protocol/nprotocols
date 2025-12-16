module nerge_oracle::nerge_oracle;

use nerge_math_lib::math;
use sui::clock::{Self, Clock};
use sui::event;
use sui::object::{Self, UID, ID};
use sui::tx_context::{Self, TxContext};
use sui::vec_map::{Self, VecMap};
use sui::vec_set::{Self, VecSet};

// ==================== Structs ====================

/// Main oracle aggregator
public struct PriceFeed has key {
    id: UID,
    /// Asset pair identifier (e.g., "SUI/USDC")
    pair: vector<u8>,
    /// Current consensus price (Q64.64 fixed point)
    consensus_price: u128,
    /// Last update timestamp
    last_update: u64,
    /// Oracle sources and their reports
    sources: VecMap<address, OracleReport>,
    /// Registered oracle addresses
    registered_oracles: VecSet<address>,
    /// Stake per oracle
    oracle_stakes: VecMap<address, u64>,
    /// Total stake
    total_stake: u64,
    /// Configuration
    min_sources: u64,
    outlier_threshold: u64, // Standard deviations (e.g., 2 or 3)
    max_age_ms: u64, // Maximum price age in milliseconds
}

/// Individual oracle report
public struct OracleReport has copy, drop, store {
    price: u128, // Q64.64 fixed point
    timestamp: u64,
    confidence: u64, // Basis points (10000 = 100% confidence)
}

/// Oracle registration capability
public struct OracleRegistration has key, store {
    id: UID,
    oracle_address: address,
    feed_id: ID,
}

/// Valid report for consensus calculation (internal use)
public struct ValidReport has copy, drop, store {
    oracle: address,
    price: u128,
    stake: u64,
}

/// Slash receipt for slashed oracle
public struct SlashReceipt has key {
    id: UID,
    oracle: address,
    amount: u64,
    reason: vector<u8>,
}

// ==================== Events ====================

public struct PriceUpdated has copy, drop {
    feed_id: ID,
    old_price: u128,
    new_price: u128,
    sources_used: u64,
    timestamp: u64,
}

public struct OracleSlashed has copy, drop {
    feed_id: ID,
    oracle: address,
    deviation: u128,
    slash_amount: u64,
}

public struct OracleRegistered has copy, drop {
    feed_id: ID,
    oracle: address,
    stake: u64,
}

// ==================== Core Functions ====================

/// Submit price using split u64s (to avoid CLI parsing issues with u128)
public entry fun submit_price_split(
    feed: &mut PriceFeed,
    registration: &OracleRegistration,
    price_high: u64,
    price_low: u64,
    confidence: u64,
    clock: &Clock,
    ctx: &TxContext,
) {
    let price = ((price_high as u128) << 64) | (price_low as u128);
    submit_price(feed, registration, price, confidence, clock, ctx);
}

/// Submit price report from oracle
public entry fun submit_price(
    feed: &mut PriceFeed,
    registration: &OracleRegistration,
    price: u128,
    confidence: u64,
    clock: &Clock,
    ctx: &TxContext,
) {
    let oracle_addr = tx_context::sender(ctx);
    assert!(registration.oracle_address == oracle_addr, E_UNAUTHORIZED_ORACLE);
    assert!(vec_set::contains(&feed.registered_oracles, &oracle_addr), E_NOT_REGISTERED);

    let timestamp = clock::timestamp_ms(clock);

    let report = OracleReport {
        price,
        timestamp,
        confidence,
    };

    // Update or insert report
    if (vec_map::contains(&feed.sources, &oracle_addr)) {
        let old_report = vec_map::get_mut(&mut feed.sources, &oracle_addr);
        *old_report = report;
    } else {
        vec_map::insert(&mut feed.sources, oracle_addr, report);
    };

    // Attempt to update consensus price
    try_update_consensus(feed, clock);
}

/// Create a new price feed (Admin only in production, open for testnet)
public entry fun create_price_feed(
    pair: vector<u8>,
    min_sources: u64,
    outlier_threshold: u64,
    max_age_ms: u64,
    ctx: &mut TxContext,
) {
    let feed = PriceFeed {
        id: object::new(ctx),
        pair,
        consensus_price: 0,
        last_update: 0,
        sources: vec_map::empty(),
        registered_oracles: vec_set::empty(),
        oracle_stakes: vec_map::empty(),
        total_stake: 0,
        min_sources,
        outlier_threshold,
        max_age_ms,
    };
    transfer::share_object(feed);
}

/// Register a new oracle
public entry fun register_oracle(feed: &mut PriceFeed, ctx: &mut TxContext) {
    let oracle_addr = tx_context::sender(ctx);

    // Register in the feed if not already registered
    if (!vec_set::contains(&feed.registered_oracles, &oracle_addr)) {
        vec_set::insert(&mut feed.registered_oracles, oracle_addr);
        vec_map::insert(&mut feed.oracle_stakes, oracle_addr, 1000); // Default stake
        feed.total_stake = feed.total_stake + 1000;
    };

    // Create and transfer registration capability
    let registration = OracleRegistration {
        id: object::new(ctx),
        oracle_address: oracle_addr,
        feed_id: object::id(feed),
    };
    transfer::public_transfer(registration, oracle_addr);

    event::emit(OracleRegistered {
        feed_id: object::id(feed),
        oracle: oracle_addr,
        stake: 1000,
    });
}

/// Update consensus price using weighted median (Theorem 2.10)
fun try_update_consensus(feed: &mut PriceFeed, clock: &Clock) {
    let current_time = clock::timestamp_ms(clock);

    // Collect valid reports (not too old)
    let mut valid_reports = vector::empty<ValidReport>();
    let sources = vec_map::keys(&feed.sources);
    let mut i = 0;

    while (i < vector::length(&sources)) {
        let oracle_addr = *vector::borrow(&sources, i);
        let report = vec_map::get(&feed.sources, &oracle_addr);

        if (current_time - report.timestamp <= feed.max_age_ms) {
            let stake = *vec_map::get(&feed.oracle_stakes, &oracle_addr);
            vector::push_back(
                &mut valid_reports,
                // TODO: copying out this "oracle_addr" may not be the right solution... verify
                ValidReport { oracle: copy oracle_addr, price: report.price, stake },
            );
        };

        i = i + 1;
    };

    // Need minimum number of sources
    if (vector::length(&valid_reports) < feed.min_sources) {
        return
    };

    // Calculate weighted median
    let old_price = feed.consensus_price;
    let new_price = calculate_weighted_median(&valid_reports, feed.total_stake);

    // Detect and slash outliers
    detect_and_slash_outliers(feed, new_price, &valid_reports);

    feed.consensus_price = new_price;
    feed.last_update = current_time;

    event::emit(PriceUpdated {
        feed_id: object::id(feed),
        old_price,
        new_price,
        sources_used: vector::length(&valid_reports),
        timestamp: current_time,
    });
}

/// Calculate stake-weighted median (Definition 2.15)
fun calculate_weighted_median(reports: &vector<ValidReport>, total_stake: u64): u128 {
    // Sort reports by price
    let mut sorted = *reports;
    sort_by_price(&mut sorted);

    let half_stake = total_stake / 2;
    let mut cumulative_stake = 0u64;
    let mut i = 0;

    while (i < vector::length(&sorted)) {
        let report = *vector::borrow(&sorted, i);
        cumulative_stake = cumulative_stake + report.stake;

        if (cumulative_stake >= half_stake) {
            return report.price
        };

        i = i + 1;
    };

    // Shouldn't reach here if total_stake is correct
    let last_report = *vector::borrow(&sorted, vector::length(&sorted) - 1);
    last_report.price
}

/// Detect outliers and slash (Definition 2.16, Theorem 2.11)
fun detect_and_slash_outliers(
    feed: &mut PriceFeed,
    consensus_price: u128,
    reports: &vector<ValidReport>,
) {
    // Calculate standard deviation
    let std_dev = calculate_std_dev(reports, consensus_price);
    let threshold = std_dev * (feed.outlier_threshold as u128);

    let mut i = 0;
    while (i < vector::length(reports)) {
        let report = *vector::borrow(reports, i);
        let deviation = if (report.price > consensus_price) {
            report.price - consensus_price
        } else {
            consensus_price - report.price
        };

        // Check if outlier
        if (deviation > threshold) {
            // Calculate slash amount (quadratic: κ * d²)
            let slash_amount = calculate_slash_amount(
                deviation,
                consensus_price,
                report.stake,
            );

            // Apply slash
            let current_stake = vec_map::get_mut(&mut feed.oracle_stakes, &report.oracle);
            if (*current_stake > slash_amount) {
                *current_stake = *current_stake - slash_amount;
                feed.total_stake = feed.total_stake - slash_amount;
            } else {
                feed.total_stake = feed.total_stake - *current_stake;
                *current_stake = 0;
                // Remove oracle if fully slashed
                vec_set::remove(&mut feed.registered_oracles, &report.oracle);
            };

            event::emit(OracleSlashed {
                feed_id: object::id(feed),
                oracle: report.oracle,
                deviation,
                slash_amount,
            });
        };

        i = i + 1;
    };
}

/// Calculate slash amount: min(stake, κ * d²)
fun calculate_slash_amount(deviation: u128, consensus: u128, stake: u64): u64 {
    // κ = 1000 (calibrated constant)
    let kappa = 1000u128;

    // Normalize deviation to percentage
    let deviation_pct = deviation * 10000 / consensus;

    // Quadratic penalty: κ * (deviation%)²
    let penalty = kappa * deviation_pct * deviation_pct / 100000000;

    let slash_amount = math::min_u128(penalty, stake as u128) as u64;
    slash_amount
}

// ==================== Helper Functions ====================

/// Calculate standard deviation of prices
fun calculate_std_dev(reports: &vector<ValidReport>, mean: u128): u128 {
    if (vector::is_empty(reports)) {
        return 0
    };

    let mut sum_squared_diff = 0u128;
    let mut i = 0;

    while (i < vector::length(reports)) {
        let report = *vector::borrow(reports, i);
        let diff = if (report.price > mean) {
            report.price - mean
        } else {
            mean - report.price
        };
        sum_squared_diff = sum_squared_diff + (diff * diff);
        i = i + 1;
    };

    let variance = sum_squared_diff / (vector::length(reports) as u128);
    math::sqrt_u128(variance)
}

/// Sort reports by price (bubble sort - simple for small n)
fun sort_by_price(reports: &mut vector<ValidReport>) {
    let n = vector::length(reports);
    if (n <= 1) return;

    let mut i = 0;
    while (i < n - 1) {
        let mut j = 0;
        while (j < n - i - 1) {
            let report1 = *vector::borrow(reports, j);
            let report2 = *vector::borrow(reports, j + 1);

            if (report1.price > report2.price) {
                vector::swap(reports, j, j + 1);
            };
            j = j + 1;
        };
        i = i + 1;
    };
}

// ==================== View Functions ====================

/// Get current consensus price
public fun get_price(feed: &PriceFeed): u64 {
    math::from_q64_64(feed.consensus_price)
}

/// Get price with full precision
public fun get_price_precise(feed: &PriceFeed): u128 {
    feed.consensus_price
}

/// Check if price is fresh
public fun is_price_fresh(feed: &PriceFeed, clock: &Clock): bool {
    let current_time = clock::timestamp_ms(clock);
    current_time - feed.last_update <= feed.max_age_ms
}

/// Get number of active oracles
public fun get_active_oracles(feed: &PriceFeed): u64 {
    vec_set::size(&feed.registered_oracles)
}

#[test_only]
public fun create_price_feed_for_testing(ctx: &mut TxContext): PriceFeed {
    PriceFeed {
        id: object::new(ctx),
        pair: vector::empty(),
        consensus_price: 0,
        last_update: 0,
        sources: vec_map::empty(),
        registered_oracles: vec_set::empty(),
        oracle_stakes: vec_map::empty(),
        total_stake: 0,
        min_sources: 1,
        outlier_threshold: 100,
        max_age_ms: 60000,
    }
}

#[test_only]
public fun share_price_feed_for_testing(feed: PriceFeed) {
    transfer::share_object(feed);
}

#[test_only]
public fun set_price_for_testing(feed: &mut PriceFeed, price: u128) {
    feed.consensus_price = price;
}

#[test_only]
public fun destroy_for_testing(feed: PriceFeed) {
    let PriceFeed {
        id,
        pair: _,
        consensus_price: _,
        last_update: _,
        sources: _,
        registered_oracles: _,
        oracle_stakes: _,
        total_stake: _,
        min_sources: _,
        outlier_threshold: _,
        max_age_ms: _,
    } = feed;
    object::delete(id);
}

// ==================== Error Codes ====================

const E_UNAUTHORIZED_ORACLE: u64 = 300;
const E_NOT_REGISTERED: u64 = 301;
const E_INSUFFICIENT_SOURCES: u64 = 302;
const E_STALE_PRICE: u64 = 303;
const E_INSUFFICIENT_STAKE: u64 = 304;

// ==================== Getters ====================

public fun get_latest_price(feed: &PriceFeed): u128 {
    feed.consensus_price
}

public fun get_confidence(feed: &PriceFeed): u64 {
    // Simple confidence metric: % of stake agreeing within threshold
    // For now return a placeholder or calculate based on active sources
    // If we have > 3 sources, high confidence.
    let count = get_active_oracles(feed);
    if (count >= 5) { 10000 } else if (count >= 3) { 8000 } else { 5000 }
}
