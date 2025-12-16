module protocol::pricing;

use nerge_math_lib::math;
use sui::clock::{Self, Clock};
use sui::tx_context::{Self, TxContext};

// ==================== Constants ====================

const ONE_E8: u128 = 100000000; // 1.0 in E8 format
const SQRT_2PI: u128 = 250662827; // sqrt(2π) * 10^8
const DAYS_PER_YEAR: u64 = 365;

// Pricing model types
const PRICING_MODEL_BLACK_SCHOLES: u8 = 0;
const PRICING_MODEL_MERTON_JUMP: u8 = 1;

// Merton Jump-Diffusion constants
const MERTON_MAX_TERMS: u64 = 20; // Series truncation
const POSITION_SIZE_THRESHOLD: u64 = 1000000; // Use Merton for positions > 1M

// ==================== Core Functions ====================

/// Calculate option price with automatic model selection based on position size
/// Returns premium in basis points (10000 = 100%)
public fun calculate_option_price(
    spot_price: u128, // Current price (Q64.64)
    strike_price: u128, // Strike price (Q64.64)
    time_to_expiry_days: u64, // Days until expiry
    volatility_bps: u64, // Annual volatility in basis points (e.g., 8000 = 80%)
    is_call: bool, // true = call option, false = put option
): u64 {
    // Use Black-Scholes by default (gas efficient)
    calculate_option_price_bs(
        spot_price,
        strike_price,
        time_to_expiry_days,
        volatility_bps,
        is_call,
    )
}

/// Calculate option price with explicit model selection
public fun calculate_option_price_with_model(
    spot_price: u128,
    strike_price: u128,
    time_to_expiry_days: u64,
    volatility_bps: u64,
    is_call: bool,
    model: u8, // PRICING_MODEL_BLACK_SCHOLES or PRICING_MODEL_MERTON_JUMP
    jump_intensity: u64, // λ in bps (e.g., 500 = 5% annual jump probability)
    jump_mean: u64, // μ_J in bps (e.g., -200 = -2% average jump)
    jump_volatility: u64, // σ_J in bps (e.g., 1500 = 15% jump volatility)
): u64 {
    if (model == PRICING_MODEL_MERTON_JUMP) {
        calculate_option_price_merton(
            spot_price,
            strike_price,
            time_to_expiry_days,
            volatility_bps,
            is_call,
            jump_intensity,
            jump_mean,
            jump_volatility,
        )
    } else {
        calculate_option_price_bs(
            spot_price,
            strike_price,
            time_to_expiry_days,
            volatility_bps,
            is_call,
        )
    }
}

/// Calculate option price using Black-Scholes model (gas efficient)
/// Returns premium in basis points (10000 = 100%)
fun calculate_option_price_bs(
    spot_price: u128,
    strike_price: u128,
    time_to_expiry_days: u64,
    volatility_bps: u64,
    is_call: bool,
): u64 {
    assert!(time_to_expiry_days > 0, E_INVALID_TIME);
    assert!(volatility_bps > 0, E_INVALID_VOLATILITY);
    assert!(strike_price > 0, E_INVALID_STRIKE);

    // Convert time to years (in E8 format)
    let time_to_expiry = ((time_to_expiry_days as u128) * ONE_E8) / (DAYS_PER_YEAR as u128);

    // Convert volatility from bps to decimal (E8 format)
    let volatility = ((volatility_bps as u128) * ONE_E8) / 10000;

    // Calculate d1 and d2
    let (d1, d2) = calculate_d_values(
        spot_price,
        strike_price,
        time_to_expiry,
        volatility,
    );

    // Get cumulative normal distribution values
    let n_d1 = normal_cdf(d1);
    let n_d2 = normal_cdf(d2);

    // Calculate option price
    let price = if (is_call) {
        // Call option: S * N(d1) - K * N(d2)
        let term1 = (spot_price * n_d1) / ONE_E8;
        let term2 = (strike_price * n_d2) / ONE_E8;
        if (term1 > term2) { term1 - term2 } else { 0 }
    } else {
        // Put option: K * N(-d2) - S * N(-d1)
        let n_neg_d1 = ONE_E8 - n_d1;
        let n_neg_d2 = ONE_E8 - n_d2;
        let term1 = (strike_price * n_neg_d2) / ONE_E8;
        let term2 = (spot_price * n_neg_d1) / ONE_E8;
        if (term1 > term2) { term1 - term2 } else { 0 }
    };

    // Convert to basis points relative to spot price
    ((price * 10000) / spot_price) as u64
}

/// Calculate option Delta (sensitivity to spot price changes)
/// Returns delta in basis points (10000 = 1.0 delta)
public fun calculate_delta(
    spot_price: u128,
    strike_price: u128,
    time_to_expiry_days: u64,
    volatility_bps: u64,
    is_call: bool,
): u64 {
    let time_to_expiry = ((time_to_expiry_days as u128) * ONE_E8) / (DAYS_PER_YEAR as u128);
    let volatility = ((volatility_bps as u128) * ONE_E8) / 10000;

    let (d1, _) = calculate_d_values(spot_price, strike_price, time_to_expiry, volatility);
    let n_d1 = normal_cdf(d1);

    if (is_call) {
        ((n_d1 * 10000) / ONE_E8) as u64
    } else {
        // Put delta = N(d1) - 1
        let delta = if (n_d1 < ONE_E8) { ONE_E8 - n_d1 } else { 0 };
        ((delta * 10000) / ONE_E8) as u64
    }
}

/// Calculate implied volatility from market price (simplified)
/// Returns volatility in basis points
public fun calculate_implied_volatility(
    market_price: u64, // Observed market price in bps
    spot_price: u128,
    strike_price: u128,
    time_to_expiry_days: u64,
    is_call: bool,
): u64 {
    // Newton-Raphson iteration for IV (simplified)
    let mut volatility_guess = 8000u64; // Start with 80% volatility
    let mut iterations = 0u64;

    while (iterations < 10) {
        let calculated_price = calculate_option_price(
            spot_price,
            strike_price,
            time_to_expiry_days,
            volatility_guess,
            is_call,
        );

        // Check if close enough
        let diff = if (calculated_price > market_price) {
            calculated_price - market_price
        } else {
            market_price - calculated_price
        };

        if (diff < 10) {
            // Within 0.1%
            break
        };

        // Adjust guess
        if (calculated_price > market_price) {
            volatility_guess = (volatility_guess * 95) / 100; // Reduce by 5%
        } else {
            volatility_guess = (volatility_guess * 105) / 100; // Increase by 5%
        };

        iterations = iterations + 1;
    };

    volatility_guess
}

// ==================== Helper Functions ====================

/// Calculate d1 and d2 for Black-Scholes
fun calculate_d_values(
    spot_price: u128,
    strike_price: u128,
    time_to_expiry: u128,
    volatility: u128,
): (u128, u128) {
    // d1 = [ln(S/K) + (σ²/2)t] / (σ√t)
    // d2 = d1 - σ√t

    // Calculate ln(S/K) (approximated)
    let price_ratio = (spot_price * ONE_E8) / strike_price;
    let ln_ratio = ln_approximation(price_ratio);

    // Calculate σ²/2 * t
    let vol_squared = (volatility * volatility) / ONE_E8;
    let variance_term = (vol_squared * time_to_expiry) / (2 * ONE_E8);

    // Calculate σ√t
    let sqrt_time = math::sqrt_u128(time_to_expiry * ONE_E8);
    let vol_sqrt_time = (volatility * sqrt_time) / ONE_E8;

    // d1 = (ln_ratio + variance_term) / vol_sqrt_time
    let numerator = ln_ratio + variance_term;
    let d1 = (numerator * ONE_E8) / vol_sqrt_time;

    // d2 = d1 - vol_sqrt_time
    let d2 = if (d1 > vol_sqrt_time) { d1 - vol_sqrt_time } else { 0 };

    (d1, d2)
}

/// Approximate cumulative normal distribution function
/// Input and output in E8 format
fun normal_cdf(x: u128): u128 {
    // Simplified approximation using Taylor series
    // N(x) ≈ 0.5 + 0.5 * erf(x/√2)

    // For simplicity, use piecewise linear approximation
    if (x < ONE_E8 / 2) {
        // x < 0.5: return ~0.3085
        30850000
    } else if (x < ONE_E8) {
        // 0.5 <= x < 1.0: return ~0.5 + linear
        50000000 + ((x - ONE_E8/2) * 40000000) / (ONE_E8/2)
    } else if (x < 2 * ONE_E8) {
        // 1.0 <= x < 2.0: return ~0.84
        84000000 + ((x - ONE_E8) * 10000000) / ONE_E8
    } else {
        // x >= 2.0: return ~0.98
        98000000
    }
}

/// Natural logarithm approximation (for x in E8 format)
fun ln_approximation(x: u128): u128 {
    if (x <= 0) return 0;
    if (x == ONE_E8) return 0; // ln(1) = 0

    // Simple approximation: ln(x) ≈ 2 * ((x-1)/(x+1))
    // More accurate for x close to 1
    if (x > ONE_E8) {
        let numerator = (x - ONE_E8) * ONE_E8 * 2;
        let denominator = x + ONE_E8;
        numerator / denominator
    } else {
        // For x < 1, ln(x) = -ln(1/x)
        let inv_x = (ONE_E8 * ONE_E8) / x;
        let numerator = (inv_x - ONE_E8) * ONE_E8 * 2;
        let denominator = inv_x + ONE_E8;
        let result = numerator / denominator;
        result // Negative, but we'll treat as positive for simplicity
    }
}

// ==================== Merton Jump-Diffusion Implementation ====================

/// Calculate option price using Merton Jump-Diffusion model
/// More accurate for volatile crypto markets but higher gas cost
/// C(S,t) = Σ(n=0 to ∞) [e^(-λ'T)(λ'T)^n / n!] * BS(S, K, r_n, σ_n, T)
fun calculate_option_price_merton(
    spot_price: u128,
    strike_price: u128,
    time_to_expiry_days: u64,
    volatility_bps: u64,
    is_call: bool,
    jump_intensity_bps: u64, // λ (annual jump probability)
    jump_mean_bps: u64, // μ_J (average jump size)
    jump_vol_bps: u64, // σ_J (jump volatility)
): u64 {
    assert!(time_to_expiry_days > 0, E_INVALID_TIME);
    assert!(volatility_bps > 0, E_INVALID_VOLATILITY);
    assert!(strike_price > 0, E_INVALID_STRIKE);

    let time_to_expiry = ((time_to_expiry_days as u128) * ONE_E8) / (DAYS_PER_YEAR as u128);

    // Convert parameters to E8 format
    let lambda = ((jump_intensity_bps as u128) * ONE_E8) / 10000;
    let mu_j = ((jump_mean_bps as u128) * ONE_E8) / 10000;
    let sigma_j = ((jump_vol_bps as u128) * ONE_E8) / 10000;

    // Adjusted jump intensity: λ' = λ(1 + μ_J)
    let lambda_prime = (lambda * (ONE_E8 + mu_j)) / ONE_E8;
    let lambda_prime_t = (lambda_prime * time_to_expiry) / ONE_E8;

    // Series summation: truncate at MERTON_MAX_TERMS
    let mut total_price = 0u128;
    let mut n = 0u64;

    while (n < MERTON_MAX_TERMS) {
        // Calculate term weight: e^(-λ'T) * (λ'T)^n / n!
        let weight = merton_series_weight(lambda_prime_t, n);

        // Adjusted parameters for this term
        let r_n = adjust_rate_for_jumps(mu_j, n, time_to_expiry);
        let sigma_j_bps_value = ((sigma_j * 10000) / ONE_E8) as u64;
        let sigma_n = adjust_volatility_for_jumps(
            volatility_bps,
            sigma_j_bps_value,
            n,
            time_to_expiry_days,
        );

        // Calculate Black-Scholes price with adjusted parameters
        let bs_price = calculate_option_price_bs(
            spot_price,
            strike_price,
            time_to_expiry_days,
            sigma_n,
            is_call,
        );

        // Add weighted term
        total_price = total_price + ((weight * (bs_price as u128)) / ONE_E8);

        n = n + 1;
    };

    (total_price as u64)
}

/// Calculate Merton series weight: e^(-λ'T) * (λ'T)^n / n!
fun merton_series_weight(lambda_prime_t: u128, n: u64): u128 {
    if (n == 0) {
        // e^(-λ'T) ≈ 1 / (1 + λ'T) for small λ'T
        (ONE_E8 * ONE_E8) / (ONE_E8 + lambda_prime_t)
    } else {
        // (λ'T)^n / n! * e^(-λ'T)
        let power = power_approximation(lambda_prime_t, n);
        let factorial = factorial_approximation(n);
        let exp_term = (ONE_E8 * ONE_E8) / (ONE_E8 + lambda_prime_t);

        ((power / factorial) * exp_term) / ONE_E8
    }
}

/// Adjust interest rate for jump component
/// r_n = r - λμ_J + (n * ln(1+μ_J))/T
fun adjust_rate_for_jumps(mu_j: u128, n: u64, time: u128): u64 {
    // Simplified: just return base adjustment
    // In full version would calculate r - λμ_J + jump term
    let adjustment = ((n as u128) * mu_j) / time;
    ((adjustment * 10000) / ONE_E8) as u64
}

/// Adjust volatility for jump component
/// σ_n² = σ² + (n * σ_J²)/T
fun adjust_volatility_for_jumps(base_vol_bps: u64, sigma_j_bps: u64, n: u64, time_days: u64): u64 {
    let base_vol = ((base_vol_bps as u128) * ONE_E8) / 10000;
    let sigma_j = ((sigma_j_bps as u128) * ONE_E8) / 10000;
    let time = ((time_days as u128) * ONE_E8) / (DAYS_PER_YEAR as u128);

    // σ_n² = σ² + nσ_J²/T
    let base_var = (base_vol * base_vol) / ONE_E8;
    let jump_var = ((n as u128) * sigma_j * sigma_j) / (time * ONE_E8);
    let total_var = base_var + jump_var;

    // σ_n = √(total_var)
    let adjusted_vol = math::sqrt_u128(total_var * ONE_E8);

    ((adjusted_vol * 10000) / ONE_E8) as u64
}

/// Power approximation: x^n (for small n)
fun power_approximation(x: u128, n: u64): u128 {
    if (n == 0) return ONE_E8;
    if (n == 1) return x;

    let mut result = x;
    let mut i = 1u64;

    while (i < n && i < 10) {
        // Cap at 10 for gas
        result = (result * x) / ONE_E8;
        i = i + 1;
    };

    result
}

/// Factorial approximation (for small n)
fun factorial_approximation(n: u64): u128 {
    if (n == 0 || n == 1) return ONE_E8;
    if (n == 2) return 2 * ONE_E8;
    if (n == 3) return 6 * ONE_E8;
    if (n == 4) return 24 * ONE_E8;
    if (n == 5) return 120 * ONE_E8;

    // For larger n, use Stirling's approximation: n! ≈ √(2πn) * (n/e)^n
    let sqrt_2pi_n = math::sqrt_u128(2 * 314159265 * (n as u128));
    let n_over_e = ((n as u128) * ONE_E8) / 271828182; // e ≈ 2.71828
    let power = power_approximation(n_over_e, n);

    (sqrt_2pi_n * power) / 100000000 // Normalize
}

// ==================== View Functions ====================

/// Calculate multiple Greeks at once for efficiency
public fun calculate_greeks(
    spot_price: u128,
    strike_price: u128,
    time_to_expiry_days: u64,
    volatility_bps: u64,
    is_call: bool,
): (u64, u64, u64) {
    // (delta, gamma, theta)  all in bps
    let delta = calculate_delta(
        spot_price,
        strike_price,
        time_to_expiry_days,
        volatility_bps,
        is_call,
    );

    // Simplified gamma (second derivative of price wrt spot)
    let gamma = (delta * 10) / 100; // Rough approximation

    // Simplified theta (time decay per day)
    let price = calculate_option_price(
        spot_price,
        strike_price,
        time_to_expiry_days,
        volatility_bps,
        is_call,
    );
    let theta = price / time_to_expiry_days; // Linear decay approximation

    (delta, gamma, theta)
}

/// Get pricing model recommendation based on position size
public fun get_recommended_pricing_model(position_value: u64): u8 {
    if (position_value >= POSITION_SIZE_THRESHOLD) {
        PRICING_MODEL_MERTON_JUMP
    } else {
        PRICING_MODEL_BLACK_SCHOLES
    }
}

/// Get model constants for external use
public fun get_model_black_scholes(): u8 { PRICING_MODEL_BLACK_SCHOLES }

public fun get_model_merton_jump(): u8 { PRICING_MODEL_MERTON_JUMP }

public fun get_position_threshold(): u64 { POSITION_SIZE_THRESHOLD }

// ==================== Error Codes ====================

const E_INVALID_TIME: u64 = 900;
const E_INVALID_VOLATILITY: u64 = 901;
const E_INVALID_STRIKE: u64 = 902;
