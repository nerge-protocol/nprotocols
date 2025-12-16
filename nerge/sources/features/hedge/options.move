module protocol::options;

use nerge_math_lib::math;
use nerge_oracle::nerge_oracle::{Self as oracle, PriceFeed};
use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::event;

// ==================== Structs ====================

/// Options vault that provides IL hedges
public struct OptionsVault<phantom BASE, phantom QUOTE> has key {
    id: UID,
    /// Collateral backing options
    collateral: Balance<BASE>,
    /// Total options written
    total_options_written: u64,
    /// Active hedges
    active_hedges: u64,
    /// Premium collected
    premium_pool: Balance<QUOTE>,
    /// Risk parameters
    max_utilization: u64, // Basis points (e.g., 8000 = 80%)
    min_collateral_ratio: u64, // Basis points
    /// Pricing parameters
    implied_volatility: u64, // Basis points (e.g., 8000 = 80% vol)
    risk_free_rate: u64, // Basis points
}

/// Hedge position (put + call collar)
public struct HedgePosition<phantom BASE, phantom QUOTE> has key, store {
    id: UID,
    vault_id: ID,
    /// LP position being hedged
    lp_position_id: ID,
    /// Put option (downside protection)
    put_strike: u64, // In QUOTE per BASE
    put_size: u64,
    /// Call option (upside cap)
    call_strike: u64,
    call_size: u64,
    /// Premium paid
    premium_paid: u64,
    /// Expiry
    expiry_epoch: u64,
    /// Creation time
    created_at: u64,
}

// ==================== Events ====================

public struct HedgeCreated<phantom BASE, phantom QUOTE> has copy, drop {
    hedge_id: ID,
    lp_position_id: ID,
    put_strike: u64,
    call_strike: u64,
    premium: u64,
    expiry: u64,
}

public struct HedgeExercised<phantom BASE, phantom QUOTE> has copy, drop {
    hedge_id: ID,
    payout: u64,
    option_type: u8, // 0 = put, 1 = call
}

// ==================== Core Functions ====================

/// Create hedge for LP position
public fun create_hedge<BASE, QUOTE>(
    vault: &mut OptionsVault<BASE, QUOTE>,
    lp_position_id: ID,
    notional_value: u64,
    duration_epochs: u64,
    oracle: &PriceFeed,
    premium_payment: Coin<QUOTE>,
    ctx: &mut TxContext,
): HedgePosition<BASE, QUOTE> {
    let current_price = oracle::get_price(oracle);

    // Calculate optimal strikes (from whitepaper Theorem 2.2)
    let (put_strike, call_strike) = calculate_optimal_strikes(
        current_price,
        vault.implied_volatility,
        duration_epochs,
    );

    // Calculate premium using Black-Scholes with jump diffusion
    let premium_required = calculate_hedge_premium(
        current_price,
        put_strike,
        call_strike,
        notional_value,
        vault.implied_volatility,
        vault.risk_free_rate,
        duration_epochs,
    );

    let premium_paid = coin::value(&premium_payment);
    assert!(premium_paid >= premium_required, E_INSUFFICIENT_PREMIUM);

    // Add premium to pool
    balance::join(
        &mut vault.premium_pool,
        coin::into_balance(premium_payment),
    );

    vault.active_hedges = vault.active_hedges + 1;
    vault.total_options_written = vault.total_options_written + notional_value;

    let hedge = HedgePosition<BASE, QUOTE> {
        id: object::new(ctx),
        vault_id: object::id(vault),
        lp_position_id,
        put_strike,
        put_size: notional_value,
        call_strike,
        call_size: notional_value,
        premium_paid,
        expiry_epoch: tx_context::epoch(ctx) + duration_epochs,
        created_at: tx_context::epoch(ctx),
    };

    event::emit(HedgeCreated<BASE, QUOTE> {
        hedge_id: object::id(&hedge),
        lp_position_id,
        put_strike,
        call_strike,
        premium: premium_paid,
        expiry: hedge.expiry_epoch,
    });

    hedge
}

/// Exercise hedge if profitable
public fun exercise_hedge<BASE, QUOTE>(
    vault: &mut OptionsVault<BASE, QUOTE>,
    hedge: &mut HedgePosition<BASE, QUOTE>,
    oracle: &PriceFeed,
    ctx: &mut TxContext,
): Option<Coin<QUOTE>> {
    assert!(tx_context::epoch(ctx) <= hedge.expiry_epoch, E_HEDGE_EXPIRED);

    let current_price = oracle::get_price(oracle);
    let mut payout = 0u64;
    let mut option_type = 255u8;

    // Check put option (downside protection)
    if (current_price < hedge.put_strike) {
        let price_diff = hedge.put_strike - current_price;
        payout =
            ((hedge.put_size as u128) * (price_diff as u128) / (hedge.put_strike as u128)) as u64;
        option_type = 0;
    } // Check call option (upside cap)
    else if (current_price > hedge.call_strike) {
        let price_diff = current_price - hedge.call_strike;
        payout =
            ((hedge.call_size as u128) * (price_diff as u128) / (hedge.call_strike as u128)) as u64;
        option_type = 1;
    };

    if (payout > 0) {
        event::emit(HedgeExercised<BASE, QUOTE> {
            hedge_id: object::id(hedge),
            payout,
            option_type,
        });

        // Pay from premium pool (simplified - would use collateral in production)
        let payout_balance = balance::split(&mut vault.premium_pool, payout);
        option::some(coin::from_balance(payout_balance, ctx))
    } else {
        option::none()
    }
}

// ==================== Pricing Functions ====================

/// Calculate optimal strike prices (Theorem 2.2)
fun calculate_optimal_strikes(
    spot_price: u64,
    volatility_bps: u64,
    duration_epochs: u64,
): (u64, u64) {
    let volatility = (volatility_bps as u128) * math::one_e8() / 10000;
    let time_years = (duration_epochs as u128) * math::one_e8() / 365; // Assume 365 epochs/year

    let vol_sqrt_t = math::sqrt_u128(
        volatility * time_years / math::one_e8(),
    );

    // Alpha ≈ 0.5, Beta ≈ 0.3 (from whitepaper)
    let alpha = 5000; // 0.5 in basis points
    let beta = 3000; // 0.3 in basis points

    // Put strike: S₀ * e^(-α*σ*√T)
    let put_multiplier = math::exp_negative_u128(
        alpha * vol_sqrt_t / 10000,
    );
    let put_strike = ((spot_price as u128) * put_multiplier / math::one_e8()) as u64;

    // Call strike: S₀ * e^(β*σ*√T)
    let call_multiplier = math::exp_u128(
        beta * vol_sqrt_t / 10000,
    );
    let call_strike = ((spot_price as u128) * call_multiplier / math::one_e8()) as u64;

    (put_strike, call_strike)
}

/// Calculate hedge premium using Black-Scholes with jump diffusion (Theorem 2.1)
fun calculate_hedge_premium(
    spot: u64,
    put_strike: u64,
    call_strike: u64,
    notional: u64,
    vol_bps: u64,
    rate_bps: u64,
    duration: u64,
): u64 {
    // Simplified Black-Scholes for put
    let put_premium = black_scholes_put(
        spot,
        put_strike,
        vol_bps,
        rate_bps,
        duration,
    );

    // Simplified Black-Scholes for call
    let call_premium = black_scholes_call(
        spot,
        call_strike,
        vol_bps,
        rate_bps,
        duration,
    );

    // Net premium = put premium - call premium (collar strategy)
    let net_premium_per_unit = if (put_premium > call_premium) {
        put_premium - call_premium
    } else {
        0
    };

    // Scale by notional
    ((notional as u128) * (net_premium_per_unit as u128) / (spot as u128)) as u64
}

/// Black-Scholes put option pricing
fun black_scholes_put(spot: u64, strike: u64, vol_bps: u64, rate_bps: u64, duration: u64): u64 {
    // Simplified implementation - production would use full BS formula
    let moneyness = if (strike > spot) {
        ((strike - spot) as u128) * 10000 / (spot as u128)
    } else {
        0
    };

    let time_value = (vol_bps as u128) * math::sqrt_u128(duration as u128) / 100;
    let intrinsic = moneyness;

    ((intrinsic + time_value) * (spot as u128) / 10000) as u64
}

/// Black-Scholes call option pricing
fun black_scholes_call(spot: u64, strike: u64, vol_bps: u64, rate_bps: u64, duration: u64): u64 {
    // Simplified implementation
    let moneyness = if (spot > strike) {
        ((spot - strike) as u128) * 10000 / (spot as u128)
    } else {
        0
    };

    let time_value = (vol_bps as u128) * math::sqrt_u128(duration as u128) / 100;
    let intrinsic = moneyness;

    ((intrinsic + time_value) * (spot as u128) / 10000) as u64
}

// ==================== View Functions ====================

/// Get hedge details
public fun get_hedge_info<BASE, QUOTE>(
    hedge: &HedgePosition<BASE, QUOTE>,
): (u64, u64, u64, u64, u64) {
    (hedge.put_strike, hedge.call_strike, hedge.put_size, hedge.premium_paid, hedge.expiry_epoch)
}

/// Calculate current hedge value
public fun calculate_hedge_value<BASE, QUOTE>(
    hedge: &HedgePosition<BASE, QUOTE>,
    current_price: u64,
): u64 {
    let mut value = 0u64;

    // Put value
    if (current_price < hedge.put_strike) {
        value = value + (hedge.put_strike - current_price);
    };

    // Call value (negative for holder)
    if (current_price > hedge.call_strike) {
        let call_cost = current_price - hedge.call_strike;
        if (value > call_cost) {
            value = value - call_cost;
        } else {
            value = 0;
        };
    };

    value
}

// ==================== Error Codes ====================

const E_INSUFFICIENT_PREMIUM: u64 = 200;
const E_HEDGE_EXPIRED: u64 = 201;
const E_VAULT_UNDERCOLLATERALIZED: u64 = 202;
const E_MAX_UTILIZATION_EXCEEDED: u64 = 203;
