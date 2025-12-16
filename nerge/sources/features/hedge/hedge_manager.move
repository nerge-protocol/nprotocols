module protocol::hedge_manager;

use acl_dex_core::pool::{Self, Pool};
use acl_dex_core::position::{Self, PositionNFT as LPPosition};
use nerge_oracle::nerge_oracle::{Self as oracle, PriceFeed};
use protocol::options::{Self, OptionsVault, HedgePosition};
use protocol::pricing;
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::event;
use sui::vec_map::{Self, VecMap};

// ==================== Constants ====================

const DEFAULT_HEDGE_THRESHOLD_BPS: u64 = 500; // 5% IL triggers hedge
const DEFAULT_REBALANCE_THRESHOLD_BPS: u64 = 1000; // 10% delta change triggers rebalance
const MAX_HEDGE_COST_BPS: u64 = 200; // Max 2% of position value for hedging
const MIN_POSITION_VALUE: u64 = 1000000; // Minimum 1M units to hedge

// ==================== Structs ====================

/// Automated hedge manager for LP positions
public struct HedgeManager<phantom X, phantom Y> has key {
    id: UID,
    /// Associated pool
    pool_id: ID,
    /// Associated options vault
    vault_id: ID,
    /// Active hedge positions
    active_hedges: VecMap<ID, HedgeInfo>, // LP_position_id -> HedgeInfo
    /// Configuration
    hedge_threshold_bps: u64,
    rebalance_threshold_bps: u64,
    auto_rebalance_enabled: bool,
    /// Statistics
    total_hedges_created: u64,
    total_il_protected: u64,
}

/// Hedge information tracking
public struct HedgeInfo has drop, store {
    hedge_position_id: ID,
    initial_value: u64,
    current_delta: u64, // in bps
    last_rebalance_epoch: u64,
    premium_paid: u64,
}

/// Hedge performance report
public struct HedgeReport has drop, store {
    position_id: ID,
    il_amount: u64, // Amount of IL incurred
    hedge_payout: u64, // Amount received from hedge
    net_result: u64, // Payout - Premium
    protection_ratio_bps: u64, // (Payout / IL) * 10000
}

// ==================== Events ====================

public struct AutoHedgeActivated<phantom X, phantom Y> has copy, drop {
    lp_position_id: ID,
    hedge_id: ID,
    initial_value: u64,
    premium: u64,
}

public struct HedgeRebalanced<phantom X, phantom Y> has copy, drop {
    lp_position_id: ID,
    old_delta: u64,
    new_delta: u64,
    rebalance_cost: u64,
}

public struct ILProtectionTriggered<phantom X, phantom Y> has copy, drop {
    lp_position_id: ID,
    il_amount: u64,
    payout: u64,
    protection_ratio_bps: u64,
}

// ==================== Core Functions ====================

/// Create hedge manager for a pool
public entry fun create_manager<X, Y>(pool_id: ID, vault_id: ID, ctx: &mut TxContext) {
    let manager = HedgeManager<X, Y> {
        id: object::new(ctx),
        pool_id,
        vault_id,
        active_hedges: vec_map::empty(),
        hedge_threshold_bps: DEFAULT_HEDGE_THRESHOLD_BPS,
        rebalance_threshold_bps: DEFAULT_REBALANCE_THRESHOLD_BPS,
        auto_rebalance_enabled: true,
        total_hedges_created: 0,
        total_il_protected: 0,
    };

    transfer::share_object(manager);
}

/// Auto-activate hedge for LP position
public fun activate_auto_hedge<X, Y>(
    manager: &mut HedgeManager<X, Y>,
    vault: &mut OptionsVault<X, Y>,
    pool: &Pool<X, Y>,
    // lp_position: &LPPosition<X, Y>,
    lp_position: &LPPosition,
    duration_epochs: u64,
    premium_payment: Coin<Y>,
    oracle: &PriceFeed,
    ctx: &mut TxContext,
): HedgePosition<X, Y> {
    let position_id = object::id(lp_position);

    // Calculate position value
    let position_value = calculate_position_value(pool, lp_position);
    assert!(position_value >= MIN_POSITION_VALUE, E_POSITION_TOO_SMALL);

    // Get premium before consuming coin
    let premium = coin::value(&premium_payment);
    assert!(premium <= (position_value * MAX_HEDGE_COST_BPS) / 10000, E_HEDGE_TOO_EXPENSIVE);

    // Create hedge
    let hedge = options::create_hedge(
        vault,
        position_id,
        position_value,
        duration_epochs,
        oracle,
        premium_payment,
        ctx,
    );

    // Calculate initial delta
    let current_price = oracle::get_price(oracle);
    let (put_strike, call_strike) = get_hedge_strikes(&hedge);
    let delta = pricing::calculate_delta(
        current_price as u128,
        put_strike as u128,
        duration_epochs,
        8000, // Default 80% volatility
        false, // Put option delta
    );

    // Track hedge
    let hedge_info = HedgeInfo {
        hedge_position_id: object::id(&hedge),
        initial_value: position_value,
        current_delta: delta,
        last_rebalance_epoch: tx_context::epoch(ctx),
        premium_paid: premium,
    };

    vec_map::insert(&mut manager.active_hedges, position_id, hedge_info);
    manager.total_hedges_created = manager.total_hedges_created + 1;

    event::emit(AutoHedgeActivated<X, Y> {
        lp_position_id: position_id,
        hedge_id: object::id(&hedge),
        initial_value: position_value,
        premium,
    });

    hedge
}

/// Check and rebalance hedge if needed
public entry fun rebalance_if_needed<X, Y>(
    manager: &mut HedgeManager<X, Y>,
    vault: &mut OptionsVault<X, Y>,
    pool: &Pool<X, Y>,
    lp_position_id: ID,
    hedge: &mut HedgePosition<X, Y>,
    oracle: &PriceFeed,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(manager.auto_rebalance_enabled, E_AUTO_REBALANCE_DISABLED);
    assert!(vec_map::contains(&manager.active_hedges, &lp_position_id), E_HEDGE_NOT_FOUND);

    let hedge_info = vec_map::get(&manager.active_hedges, &lp_position_id);
    let current_price = oracle::get_price(oracle);

    // Calculate current delta
    let (put_strike, call_strike) = get_hedge_strikes(hedge);
    let time_remaining = calculate_time_to_expiry(hedge, ctx);

    let new_delta = pricing::calculate_delta(
        current_price as u128,
        put_strike as u128,
        time_remaining,
        8000,
        false,
    );

    // Check if rebalance needed
    let delta_change = if (new_delta > hedge_info.current_delta) {
        new_delta - hedge_info.current_delta
    } else {
        hedge_info.current_delta - new_delta
    };

    if (delta_change >= manager.rebalance_threshold_bps) {
        // Perform rebalance (simplified - in production would adjust position)
        let hedge_info_mut = vec_map::get_mut(&mut manager.active_hedges, &lp_position_id);
        let old_delta = hedge_info_mut.current_delta;
        hedge_info_mut.current_delta = new_delta;
        hedge_info_mut.last_rebalance_epoch = tx_context::epoch(ctx);

        event::emit(HedgeRebalanced<X, Y> {
            lp_position_id,
            old_delta,
            new_delta,
            rebalance_cost: 0, // Simplified
        });
    };
}

/// Calculate IL and check if protection should be triggered
public fun calculate_il_protection<X, Y>(
    manager: &mut HedgeManager<X, Y>,
    pool: &Pool<X, Y>,
    lp_position: &LPPosition,
    oracle: &PriceFeed,
): HedgeReport {
    let position_id = object::id(lp_position);
    assert!(vec_map::contains(&manager.active_hedges, &position_id), E_HEDGE_NOT_FOUND);

    let hedge_info = vec_map::get(&manager.active_hedges, &position_id);
    let current_value = calculate_position_value(pool, lp_position);

    // Calculate IL
    let il_amount = if (current_value < hedge_info.initial_value) {
        hedge_info.initial_value - current_value
    } else {
        0
    };

    // For now, assume zero payout (actual would come from exercising hedge)
    let hedge_payout = 0u64;

    let net_result = if (hedge_payout > hedge_info.premium_paid) {
        hedge_payout - hedge_info.premium_paid
    } else {
        0
    };

    let protection_ratio_bps = if (il_amount > 0) {
        (hedge_payout * 10000) / il_amount
    } else {
        0
    };

    manager.total_il_protected = manager.total_il_protected + hedge_payout;

    event::emit(ILProtectionTriggered<X, Y> {
        lp_position_id: position_id,
        il_amount,
        payout: hedge_payout,
        protection_ratio_bps,
    });

    HedgeReport {
        position_id,
        il_amount,
        hedge_payout,
        net_result,
        protection_ratio_bps,
    }
}

// ==================== Helper Functions ====================

/// Calculate LP position value
fun calculate_position_value<X, Y>(pool: &Pool<X, Y>, lp_position: &LPPosition): u64 {
    // Simplified - actual would use position's liquidity and current reserves
    let (reserve_x, reserve_y) = pool::get_reserves(pool);
    let avg_value = (reserve_x + reserve_y) / 2;
    avg_value / 1000 // Rough approximation
}

/// Get hedge strike prices
fun get_hedge_strikes<BASE, QUOTE>(hedge: &HedgePosition<BASE, QUOTE>): (u64, u64) {
    // This would access hedge fields - for now return dummy values
    (9000, 11000) // 90% put, 110% call
}

/// Calculate time remaining until expiry
fun calculate_time_to_expiry<BASE, QUOTE>(
    hedge: &HedgePosition<BASE, QUOTE>,
    ctx: &TxContext,
): u64 {
    // Simplified - would check hedge expiry epoch
    30 // Default 30 days
}

// ==================== View Functions ====================

/// Get hedge status for LP position
public fun get_hedge_status<X, Y>(
    manager: &HedgeManager<X, Y>,
    lp_position_id: ID,
): (bool, u64, u64) {
    // (is_hedged, delta, premium_paid)
    if (vec_map::contains(&manager.active_hedges, &lp_position_id)) {
        let info = vec_map::get(&manager.active_hedges, &lp_position_id);
        (true, info.current_delta, info.premium_paid)
    } else {
        (false, 0, 0)
    }
}

/// Get manager statistics
public fun get_stats<X, Y>(manager: &HedgeManager<X, Y>): (u64, u64, u64) {
    (
        vec_map::size(&manager.active_hedges),
        manager.total_hedges_created,
        manager.total_il_protected,
    )
}

// ==================== Error Codes ====================

const E_POSITION_TOO_SMALL: u64 = 1000;
const E_HEDGE_TOO_EXPENSIVE: u64 = 1001;
const E_AUTO_REBALANCE_DISABLED: u64 = 1002;
const E_HEDGE_NOT_FOUND: u64 = 1003;
