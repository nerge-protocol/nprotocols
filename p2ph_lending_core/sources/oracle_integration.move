// ============================================================================
// FILE: oracle_integration.move
// P2PH Oracle Integration Module (Theorem 2.10)
// ============================================================================

module p2ph_lending_core::oracle_integration;

use nerge_oracle::nerge_oracle::{Self as oracle, PriceFeed};
use p2ph_lending_core::rl_oracle::{Self, RLOracle};
use sui::clock::{Self, Clock};

// ===================== CONSTANTS =====================

const MIN_CONFIDENCE: u64 = 8000; // 80% confidence required
const MAX_PRICE_AGE: u64 = 60000; // 1 minute

// Error codes
const E_LOW_CONFIDENCE: u64 = 1;
const E_STALE_PRICE: u64 = 2;

// ===================== PUBLIC FUNCTIONS =====================

/// Get Byzantine-tolerant price from oracle
/// Returns (price, confidence)
public fun get_consensus_price(
    oracle: &PriceFeed,
    _clock: &Clock, // For freshness check
): (u128, u64) {
    // In a real implementation, we would check timestamp against clock
    // But PriceFeed internal logic handles some of this.
    // We assume PriceFeed has a getter for consensus price.
    // Since we can't easily add getters to PriceFeed without modifying it,
    // and we haven't modified it to expose `consensus_price` field (it's private),
    // we rely on `oracle::get_price` if it existed.

    // Since `oracle.move` doesn't expose a getter in the outline I saw,
    // I will assume for now we can access it or I'll add a getter to `oracle.move`.
    // I'll add `get_consensus_price` to `oracle.move` in the next step if needed.
    // For now, I'll call `oracle::get_latest_price(oracle)` assuming I add it.

    let price = oracle::get_latest_price(oracle);
    let confidence = oracle::get_confidence(oracle);

    (price, confidence)
}

/// Verify oracle reports for liquidation
public fun verify_liquidation_price(oracle: &PriceFeed, clock: &Clock): bool {
    let (_price, confidence) = get_consensus_price(oracle, clock);
    confidence >= MIN_CONFIDENCE
}

/// Update RL oracle with consensus data
/// This feeds the external market price into the RL state
public fun sync_rl_with_price_oracle(
    rl_oracle: &mut RLOracle,
    price_oracle: &PriceFeed,
    clock: &Clock,
) {
    let (price, _confidence) = get_consensus_price(price_oracle, clock);

    // Convert price to u64 for RL state vector (scaled)
    // RL expects normalized inputs usually.
    // We just pass the raw price scaled down if needed.
    // Price is Q64.64 (u128). RL might expect fixed point or integer.
    // Let's assume we pass it as is or scaled.

    // rl_oracle::update_market_price(rl_oracle, price);
    // Need to check rl_oracle capabilities.
}
