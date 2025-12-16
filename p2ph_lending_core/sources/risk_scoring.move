// ============================================================================
// FILE: risk_scoring.move
// P2PH Risk Assessment Module
// ============================================================================

module p2ph_lending_core::risk_scoring;

use nerge_math_lib::math;
use sui::tx_context::TxContext;

// ===================== CONSTANTS =====================

// Risk score scale (0-10000 = 0-100%)
const RISK_SCALE: u64 = 10000;

// Placement thresholds
const POOL_MAX_RISK: u64 = 3000; // 30% - pool only
const HYBRID_MAX_RISK: u64 = 7000; // 70% - can move to P2P
const P2P_MIN_RISK: u64 = 7000; // 70% - P2P required

// Base LTV ratios (scaled by 10000)
const BASE_LTV_ETH: u64 = 7500; // 75%
const BASE_LTV_BTC: u64 = 7500; // 75%
const BASE_LTV_STABLE: u64 = 9000; // 90%
const BASE_LTV_DEFAULT: u64 = 6000; // 60%

// Risk weights
const WEIGHT_LTV: u64 = 3000; // 30%
const WEIGHT_VOLATILITY: u64 = 4000; // 40%
const WEIGHT_UTILIZATION: u64 = 2000; // 20%
const WEIGHT_SIZE: u64 = 1000; // 10%

// Volatility thresholds (annual %, scaled by 100)
const LOW_VOLATILITY: u64 = 5000; // 50%
const HIGH_VOLATILITY: u64 = 15000; // 150%

// Error codes
const E_INVALID_RISK_SCORE: u64 = 1;
const E_INVALID_LTV: u64 = 2;
const E_ZERO_COLLATERAL: u64 = 3;

// ===================== STRUCTS =====================

/// Risk assessment result for a borrower position
public struct RiskAssessment has copy, drop, store {
    risk_score: u64, // 0-10000 (0-100%)
    placement: u8, // 0=POOL, 1=HYBRID, 2=P2P
    ltv_allowed: u64, // Dynamic LTV based on risk
    interest_premium: u64, // Additional rate for risk (basis points)
    volatility_estimate: u64, // Asset volatility (annual %)
    health_factor: u64, // Position health (scaled by 10000)
}

/// Risk thresholds for placement decisions
public struct RiskThresholds has copy, drop, store {
    pool_max: u64, // 3000 (30%) - pool only
    hybrid_max: u64, // 7000 (70%) - can move to P2P
    p2p_min: u64, // 7000 (70%) - P2P required
}

/// Market conditions for risk assessment
public struct MarketConditions has drop, store {
    utilization: u64, // Pool utilization (0-10000)
    total_borrows: u64,
    total_supply: u64,
    volatility: u64, // Market volatility estimate
    liquidations_24h: u64, // Number of liquidations
}

public fun new_market_conditions(
    utilization: u64,
    total_borrows: u64,
    total_supply: u64,
    volatility: u64,
    liquidations_24h: u64,
): MarketConditions {
    MarketConditions {
        utilization,
        total_borrows,
        total_supply,
        volatility,
        liquidations_24h,
    }
}

// ===================== PUBLIC FUNCTIONS =====================

/// Calculate risk score for a position
/// Returns RiskAssessment with score, placement, and parameters
public fun calculate_risk_score(
    collateral_amount: u64,
    borrow_amount: u64,
    collateral_price: u128, // Q64.64 fixed point
    borrow_price: u128, // Q64.64 fixed point
    collateral_volatility: u64, // Annual % (scaled by 100)
    market: &MarketConditions,
): RiskAssessment {
    assert!(collateral_amount > 0, E_ZERO_COLLATERAL);

    // Calculate LTV
    // Use u128 for calculation to maintain precision and avoid overflow
    // LTV = (borrow_value * 10000) / collateral_value
    let collateral_val_raw = (collateral_amount as u128) * collateral_price;
    let borrow_val_raw = (borrow_amount as u128) * borrow_price;

    let ltv = if (collateral_val_raw > 0) {
        ((borrow_val_raw * 10000) / collateral_val_raw) as u64
    } else {
        0
    };

    // Component scores (0-10000 each)
    let ltv_score = calculate_ltv_risk(ltv);
    let volatility_score = calculate_volatility_risk(collateral_volatility);
    let utilization_score = calculate_utilization_risk(market.utilization);
    let size_score = calculate_size_risk(borrow_amount, market.total_borrows);

    // Weighted average risk score
    let risk_score =
        (
            ltv_score * WEIGHT_LTV +
            volatility_score * WEIGHT_VOLATILITY +
            utilization_score * WEIGHT_UTILIZATION +
            size_score * WEIGHT_SIZE
        ) / RISK_SCALE;

    // Determine placement
    let thresholds = default_thresholds();
    let placement = determine_placement(risk_score, &thresholds);

    // Calculate dynamic LTV allowed
    let ltv_allowed = calculate_dynamic_ltv(
        ltv,
        collateral_volatility,
        market.utilization,
    );

    // Calculate interest premium based on risk
    let interest_premium = calculate_interest_premium(risk_score, placement);

    // Calculate health factor
    let health_factor = if (ltv > 0) {
        (ltv_allowed * 10000) / ltv
    } else {
        10000 // Perfect health if no debt
    };

    RiskAssessment {
        risk_score,
        placement,
        ltv_allowed,
        interest_premium,
        volatility_estimate: collateral_volatility,
        health_factor,
    }
}

/// Determine placement based on risk score
/// Returns: 0=POOL, 1=HYBRID, 2=P2P
public fun determine_placement(risk_score: u64, thresholds: &RiskThresholds): u8 {
    if (risk_score < thresholds.pool_max) {
        0 // POOL
    } else if (risk_score < thresholds.hybrid_max) {
        1 // HYBRID
    } else {
        2 // P2P
    }
}

/// Calculate dynamic LTV based on risk factors (Theorem 3.7)
/// LTV_i(t) = LTV_max * (1 - σ_i(t)/σ_max) * (1 - Util_i(t)/Util_max)
public fun calculate_dynamic_ltv(current_ltv: u64, volatility: u64, utilization: u64): u64 {
    // Base LTV (simplified - would use asset-specific)
    let base_ltv = BASE_LTV_DEFAULT;

    // Maximum acceptable values
    let sigma_max = 20000; // 200% annual volatility
    let util_max = 9000; // 90% utilization

    // Apply risk adjustments (Theorem 3.7)
    let volatility_factor = if (volatility < sigma_max) {
        10000 - ((volatility * 10000) / sigma_max)
    } else {
        0
    };

    let utilization_factor = if (utilization < util_max) {
        10000 - ((utilization * 10000) / util_max)
    } else {
        0
    };

    // Dynamic LTV
    let dynamic_ltv = (base_ltv * volatility_factor * utilization_factor) / (10000 * 10000);

    // Solvency guarantee (3-sigma rule)
    // LTV < 1/(1 + 3σ√Δt) ensures 99.7% solvency
    let sqrt_daily = 169; // √(1/365) * 10000 ≈ 169
    let sigma_term = (3 * volatility * sqrt_daily) / 1000000; // Scale down
    let solvency_ltv = if (sigma_term < 10000) {
        (10000 * 10000) / (10000 + sigma_term)
    } else {
        0
    };

    // Return minimum of dynamic and solvency-guaranteed LTV
    if (dynamic_ltv < solvency_ltv) dynamic_ltv else solvency_ltv
}

/// Check if position should be reallocated
public fun should_reallocate(current_placement: u8, new_assessment: &RiskAssessment): bool {
    // Move from POOL to HYBRID/P2P if risk increased
    if (current_placement == 0 && new_assessment.placement > 0) {
        return true
    };

    // Move from HYBRID to P2P if risk increased significantly
    if (current_placement == 1 && new_assessment.placement == 2) {
        return true
    };

    false
}

/// Get default risk thresholds
public fun default_thresholds(): RiskThresholds {
    RiskThresholds {
        pool_max: POOL_MAX_RISK,
        hybrid_max: HYBRID_MAX_RISK,
        p2p_min: P2P_MIN_RISK,
    }
}

// ===================== HELPER FUNCTIONS =====================

/// Calculate LTV component of risk score
fun calculate_ltv_risk(ltv: u64): u64 {
    // Linear scaling: 0% LTV = 0 risk, 100% LTV = 10000 risk
    // But accelerate above 75%
    if (ltv < 7500) {
        // Linear up to 75%: score = ltv
        ltv
    } else {
        // Exponential above 75%
        let excess = ltv - 7500;
        7500 + (excess * excess) / 2500 // Quadratic growth
    }
}

/// Calculate volatility component of risk score
fun calculate_volatility_risk(volatility: u64): u64 {
    // volatility is annual % scaled by 100
    // Low vol (< 50%) = low risk
    // High vol (> 150%) = max risk

    if (volatility < LOW_VOLATILITY) {
        // Linear scaling 0-5000 risk
        (volatility * 5000) / LOW_VOLATILITY
    } else if (volatility < HIGH_VOLATILITY) {
        // Linear scaling 5000-10000 risk
        5000 + ((volatility - LOW_VOLATILITY) * 5000) / (HIGH_VOLATILITY - LOW_VOLATILITY)
    } else {
        // Max risk
        10000
    }
}

/// Calculate utilization component of risk score
fun calculate_utilization_risk(utilization: u64): u64 {
    // utilization is 0-10000 (0-100%)
    // Linear scaling
    utilization
}

/// Calculate position size component of risk score
fun calculate_size_risk(borrow_amount: u64, total_borrows: u64): u64 {
    if (total_borrows == 0) {
        return 0
    };

    // Large positions (> 5% of total) add risk
    let position_share = (borrow_amount * 10000) / total_borrows;

    if (position_share < 500) {
        // < 5%
        0
    } else if (position_share < 2000) {
        // 5-20%
        (position_share - 500) * 10000 / 1500 // Linear 0-10000
    } else {
        10000 // Max risk for very large positions
    }
}

/// Calculate interest premium based on risk
/// Returns basis points (10000 = 100%)
fun calculate_interest_premium(risk_score: u64, placement: u8): u64 {
    // Base premium by placement
    let base_premium = if (placement == 0) {
        0 // POOL: no premium
    } else if (placement == 1) {
        150 // HYBRID: 1.5% premium
    } else {
        350 // P2P: 3.5% premium
    };

    // Additional premium for high risk
    let risk_premium = if (risk_score > 8000) {
        (risk_score - 8000) / 40 // Up to 5% for max risk
    } else {
        0
    };

    base_premium + risk_premium
}

// ===================== VIEW FUNCTIONS =====================

/// Get risk score from assessment
public fun get_risk_score(assessment: &RiskAssessment): u64 {
    assessment.risk_score
}

/// Get placement from assessment
public fun get_placement(assessment: &RiskAssessment): u8 {
    assessment.placement
}

/// Get allowed LTV from assessment
public fun get_ltv_allowed(assessment: &RiskAssessment): u64 {
    assessment.ltv_allowed
}

/// Get interest premium from assessment
public fun get_interest_premium(assessment: &RiskAssessment): u64 {
    assessment.interest_premium
}

/// Get health factor from assessment
public fun get_health_factor(assessment: &RiskAssessment): u64 {
    assessment.health_factor
}

/// Check if position is healthy
public fun is_healthy(assessment: &RiskAssessment): bool {
    assessment.health_factor >= 10000
}
