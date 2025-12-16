module p2ph_lending_core::lending_market;

use nerge_math_lib::math;
use nerge_oracle::nerge_oracle::{Self as oracle, PriceFeed};
use p2ph_lending_core::interest_rate;
use sui::balance::{Self, Balance};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::derived_object;
use sui::event;
use sui::object::{Self, UID, ID};
use sui::table::{Self, Table};
use sui::transfer;
use sui::tx_context::{Self, TxContext};

// ==================== Structs ====================

/// Lending market for a specific asset
public struct LendingMarket<phantom T> has key {
    id: UID,
    /// Total supplied (deposits)
    total_supply: u64,
    /// Total borrowed
    total_borrows: u64,
    /// Reserve balance (available liquidity)
    reserve: Balance<T>,
    /// Accumulated protocol reserves
    protocol_reserves: Balance<T>,
    /// Interest rate model parameters
    base_rate_per_sec: u64, // In basis points per second
    multiplier_per_sec: u64,
    jump_multiplier_per_sec: u64,
    optimal_utilization: u64, // Basis points (e.g., 8000 = 80%)
    /// Collateral factor (max LTV)
    collateral_factor: u64, // Basis points
    /// Liquidation threshold
    liquidation_threshold: u64, // Basis points
    /// Liquidation penalty
    liquidation_penalty: u64, // Basis points (500 = 5%)
    /// Reserve factor (protocol cut)
    reserve_factor: u64, // Basis points (1500 = 15%)
    /// Last update timestamp
    last_update_time: u64,
    /// Accrued interest index
    borrow_index: u128, // Q64.64 fixed point
    supply_index: u128, // Q64.64 fixed point
    /// Oracle price feed ID
    oracle_feed_id: ID,
}

/// User's supply position (lender)
public struct SupplyPosition<phantom T> has key, store {
    id: UID,
    market_id: ID,
    /// Amount supplied (principal)
    principal: u64,
    /// Supply index at deposit time
    index_at_deposit: u128,
    /// Deposit timestamp
    deposit_time: u64,
}

/// User's borrow position
public struct BorrowPosition<phantom Collateral, phantom Borrow> has key, store {
    id: UID,
    market_id: ID,
    /// Collateral deposited
    collateral_amount: u64,
    collateral_balance: Balance<Collateral>,
    /// Borrowed amount (principal)
    borrow_principal: u64,
    /// Interest index at borrow time
    borrow_index: u128,
    /// Borrow timestamp
    borrow_time: u64,
    /// Borrower address
    borrower: address,
    /// Health factor at creation
    initial_health_factor: u64,
    /// Liquidation status
    liquidation_status: u8, // 0 = healthy, 1 = in liquidation
}

/// Market configuration capability
public struct MarketAdminCap has key {
    id: UID,
}

fun init(ctx: &mut TxContext) {
    transfer::transfer(MarketAdminCap { id: object::new(ctx) }, tx_context::sender(ctx));
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

// ==================== Events ====================

public struct MarketCreated<phantom T> has copy, drop {
    market_id: ID,
    collateral_factor: u64,
    liquidation_threshold: u64,
}

public struct Supplied<phantom T> has copy, drop {
    market_id: ID,
    supplier: address,
    amount: u64,
    new_total_supply: u64,
}

public struct Borrowed<phantom Collateral, phantom Borrow> has copy, drop {
    market_id: ID,
    borrower: address,
    collateral_amount: u64,
    borrow_amount: u64,
    health_factor: u64,
}

public struct Repaid<phantom Collateral, phantom Borrow> has copy, drop {
    position_id: ID,
    borrower: address,
    repay_amount: u64,
    remaining_debt: u64,
}

// ==================== Core Functions ====================

/// Create a new lending market
public entry fun create_market<T>(
    _cap: &MarketAdminCap,
    collateral_factor: u64,
    liquidation_threshold: u64,
    liquidation_penalty: u64,
    reserve_factor: u64,
    base_rate: u64,
    multiplier: u64,
    jump_multiplier: u64,
    optimal_utilization: u64,
    oracle_feed_id: ID,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(collateral_factor <= 10000, E_INVALID_COLLATERAL_FACTOR);
    assert!(liquidation_threshold <= 10000, E_INVALID_THRESHOLD);
    assert!(liquidation_threshold > collateral_factor, E_THRESHOLD_TOO_LOW);

    let market = LendingMarket<T> {
        id: object::new(ctx),
        total_supply: 0,
        total_borrows: 0,
        reserve: balance::zero(),
        protocol_reserves: balance::zero(),
        base_rate_per_sec: base_rate,
        multiplier_per_sec: multiplier,
        jump_multiplier_per_sec: jump_multiplier,
        optimal_utilization,
        collateral_factor,
        liquidation_threshold,
        liquidation_penalty,
        reserve_factor,
        last_update_time: clock::timestamp_ms(clock),
        borrow_index: math::one_q64_64(),
        supply_index: math::one_q64_64(),
        oracle_feed_id,
    };

    let market_id = object::id(&market);

    event::emit(MarketCreated<T> {
        market_id,
        collateral_factor,
        liquidation_threshold,
    });

    transfer::share_object(market);
}

/// Supply (lend) tokens to market
public fun supply<T>(
    market: &mut LendingMarket<T>,
    coin: Coin<T>,
    clock: &Clock,
    ctx: &mut TxContext,
): SupplyPosition<T> {
    accrue_interest(market, clock);

    let amount = coin::value(&coin);
    assert!(amount > 0, E_ZERO_AMOUNT);

    // Add to reserve
    balance::join(&mut market.reserve, coin::into_balance(coin));
    market.total_supply = market.total_supply + amount;

    let position = SupplyPosition<T> {
        id: object::new(ctx),
        market_id: object::id(market),
        principal: amount,
        index_at_deposit: market.supply_index,
        deposit_time: clock::timestamp_ms(clock),
    };

    event::emit(Supplied<T> {
        market_id: object::id(market),
        supplier: tx_context::sender(ctx),
        amount,
        new_total_supply: market.total_supply,
    });

    position
}

/// Entry wrapper for supply that transfers position to sender (for CLI usage)
public entry fun supply_entry<T>(
    market: &mut LendingMarket<T>,
    coin: Coin<T>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let position = supply(market, coin, clock, ctx);
    transfer::public_transfer(position, tx_context::sender(ctx));
}

// Withdraw supplied tokens
// public fun withdraw<T>(
//     market: &mut LendingMarket<T>,
//     position: SupplyPosition<T>,
//     amount: u64,
//     clock: &Clock,
//     ctx: &mut TxContext,
// ): (Coin<T>, SupplyPosition<T>) {
//     accrue_interest(market, clock);

//     let SupplyPosition {
//         id,
//         market_id,
//         principal,
//         index_at_deposit,
//         deposit_time,
//     } = position;

//     assert!(market_id == object::id(market), E_WRONG_MARKET);

//     // Calculate accrued interest
//     let current_value = math::q64_64_mul(
//         principal,
//         math::q64_64_div(market.supply_index, index_at_deposit),
//     );

//     assert!(amount <= current_value, E_INSUFFICIENT_BALANCE);
//     assert!(balance::value(&market.reserve) >= amount, E_INSUFFICIENT_LIQUIDITY);

//     // Withdraw from reserve
//     let withdrawn = coin::from_balance(
//         balance::split(&mut market.reserve, amount),
//         ctx,
//     );

//     market.total_supply = market.total_supply - amount;

//     // Create updated position
//     let new_position = SupplyPosition<T> {
//         id, // TODO: verify if we should create a new ID or using "id" destructured above
//         market_id,
//         principal: principal - amount,
//         index_at_deposit: market.supply_index,
//         deposit_time,
//     };

//     (withdrawn, new_position)
// }

/// Withdraw supplied tokens
public fun withdraw<T>(
    market: &mut LendingMarket<T>,
    position: &mut SupplyPosition<T>, // Changed to mutable reference
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<T> {
    // Only return the coin
    accrue_interest(market, clock);

    assert!(position.market_id == object::id(market), E_WRONG_MARKET);

    // Calculate accrued interest
    let current_value = math::q64_64_mul(
        position.principal,
        math::q64_64_div(market.supply_index, position.index_at_deposit),
    );

    assert!(amount <= current_value, E_INSUFFICIENT_BALANCE);
    assert!(balance::value(&market.reserve) >= amount, E_INSUFFICIENT_LIQUIDITY);

    // Withdraw from reserve
    let withdrawn = coin::from_balance(
        balance::split(&mut market.reserve, amount),
        ctx,
    );

    market.total_supply = market.total_supply - amount;

    // Update position in place
    position.principal = position.principal - amount;
    position.index_at_deposit = market.supply_index;

    withdrawn
}

/// Borrow against collateral
public fun borrow<Collateral, Borrow>(
    collateral_market: &LendingMarket<Collateral>,
    borrow_market: &mut LendingMarket<Borrow>,
    collateral: Coin<Collateral>,
    borrow_amount: u64,
    oracle: &PriceFeed,
    clock: &Clock,
    ctx: &mut TxContext,
): (BorrowPosition<Collateral, Borrow>, Coin<Borrow>) {
    accrue_interest(borrow_market, clock);

    let collateral_amount = coin::value(&collateral);
    assert!(collateral_amount > 0, E_ZERO_COLLATERAL);
    assert!(borrow_amount > 0, E_ZERO_AMOUNT);

    // Get prices from oracle (Q64.64 format)
    let collateral_price = oracle::get_price_precise(oracle);
    let borrow_price = oracle::get_price_precise(oracle);

    // Calculate collateral value in borrow asset terms
    let collateral_value = math::q64_64_mul(collateral_amount, collateral_price);
    let collateral_value_in_borrow = math::q64_64_div(
        collateral_value as u128,
        borrow_price,
    );

    // Check max borrow amount (collateral_factor is max LTV)
    let max_borrow =
        ((collateral_value_in_borrow as u64) * collateral_market.collateral_factor) / 10000;
    assert!(borrow_amount <= max_borrow, E_INSUFFICIENT_COLLATERAL);

    // Calculate initial health factor
    let health_factor = calculate_health_factor(
        collateral_value_in_borrow as u64,
        borrow_amount,
        collateral_market.liquidation_threshold,
    );
    assert!(health_factor >= 10000, E_UNHEALTHY_POSITION);

    // Check market has enough liquidity
    assert!(balance::value(&borrow_market.reserve) >= borrow_amount, E_INSUFFICIENT_LIQUIDITY);

    // Create borrow position
    let position = BorrowPosition<Collateral, Borrow> {
        id: object::new(ctx),
        market_id: object::id(borrow_market),
        collateral_amount,
        collateral_balance: coin::into_balance(collateral),
        borrow_principal: borrow_amount,
        borrow_index: borrow_market.borrow_index,
        borrow_time: clock::timestamp_ms(clock),
        borrower: tx_context::sender(ctx),
        initial_health_factor: health_factor,
        liquidation_status: 0,
    };

    // Transfer borrowed tokens
    let borrowed_coin = coin::from_balance(
        balance::split(&mut borrow_market.reserve, borrow_amount),
        ctx,
    );

    borrow_market.total_borrows = borrow_market.total_borrows + borrow_amount;

    event::emit(Borrowed<Collateral, Borrow> {
        market_id: object::id(borrow_market),
        borrower: tx_context::sender(ctx),
        collateral_amount,
        borrow_amount,
        health_factor,
    });

    (position, borrowed_coin)
}

/// Repay borrowed tokens
public fun repay<Collateral, Borrow>(
    market: &mut LendingMarket<Borrow>,
    position: &mut BorrowPosition<Collateral, Borrow>,
    repay_coin: Coin<Borrow>,
    clock: &Clock,
    ctx: &TxContext,
): u64 {
    accrue_interest(market, clock);

    let repay_amount = coin::value(&repay_coin);

    // Calculate current debt (principal + accrued interest)
    let current_debt = math::q64_64_mul(
        position.borrow_principal,
        math::q64_64_div(market.borrow_index, position.borrow_index),
    );

    let actual_repay = math::min_u64(repay_amount, current_debt);

    // Add repayment to reserve
    balance::join(&mut market.reserve, coin::into_balance(repay_coin));

    // Update position
    position.borrow_principal = if (actual_repay >= current_debt) {
        0
    } else {
        position.borrow_principal - actual_repay
    };
    position.borrow_index = market.borrow_index;

    market.total_borrows = market.total_borrows - actual_repay;

    event::emit(Repaid<Collateral, Borrow> {
        position_id: object::id(position),
        borrower: tx_context::sender(ctx),
        repay_amount: actual_repay,
        remaining_debt: position.borrow_principal,
    });

    actual_repay
}

// ==================== Helper Functions ====================

/// Accrue interest based on time elapsed
fun accrue_interest<T>(market: &mut LendingMarket<T>, clock: &Clock) {
    let current_time = clock::timestamp_ms(clock);
    let time_elapsed = current_time - market.last_update_time;

    if (time_elapsed == 0) return;

    let utilization = calculate_utilization(market);
    let borrow_rate = interest_rate::calculate_borrow_rate(
        utilization,
        market.base_rate_per_sec,
        market.multiplier_per_sec,
        market.jump_multiplier_per_sec,
        market.optimal_utilization,
    );

    // Calculate interest accrued
    let interest_factor = (borrow_rate * time_elapsed) / 1000; // Convert ms to seconds
    let interest_accumulated = (market.total_borrows * interest_factor) / 1000000000;

    // Update indices
    if (market.total_borrows > 0) {
        let borrow_index_delta = (market.borrow_index * (interest_factor as u128)) / 1000000000;
        market.borrow_index = market.borrow_index + borrow_index_delta;
    };

    if (market.total_supply > 0) {
        let supply_interest = (interest_accumulated * (10000 - market.reserve_factor)) / 10000;
        let supply_index_delta =
            (market.supply_index * (supply_interest as u128)) / (market.total_supply as u128);
        market.supply_index = market.supply_index + supply_index_delta;
    };

    market.last_update_time = current_time;
}

/// Calculate market utilization rate
fun calculate_utilization<T>(market: &LendingMarket<T>): u64 {
    if (market.total_supply == 0) return 0;
    (market.total_borrows * 10000) / market.total_supply
}

/// Calculate health factor for position
fun calculate_health_factor(
    collateral_value: u64,
    borrow_value: u64,
    liquidation_threshold: u64,
): u64 {
    if (borrow_value == 0) return 100000; // Max health
    ((collateral_value * liquidation_threshold) / 10000) * 10000 / borrow_value
}

// ==================== View Functions ====================

/// Get current borrow APY
public fun get_borrow_apy<T>(market: &LendingMarket<T>): u64 {
    let utilization = calculate_utilization(market);
    interest_rate::calculate_borrow_rate(
            utilization,
            market.base_rate_per_sec,
            market.multiplier_per_sec,
            market.jump_multiplier_per_sec,
            market.optimal_utilization
        ) * 31536000 / 10000 // Convert to APY
}

/// Get current supply APY
public fun get_supply_apy<T>(market: &LendingMarket<T>): u64 {
    let borrow_apy = get_borrow_apy(market);
    let utilization = calculate_utilization(market);
    (borrow_apy * utilization * (10000 - market.reserve_factor)) / 100000000
}

/// Get position health factor
public fun get_position_health<Collateral, Borrow>(
    position: &BorrowPosition<Collateral, Borrow>,
    collateral_market: &LendingMarket<Collateral>,
    borrow_market: &LendingMarket<Borrow>,
    oracle: &PriceFeed,
): u64 {
    let collateral_price = oracle::get_price(oracle);
    let borrow_price = oracle::get_price(oracle);

    let collateral_value = math::q64_64_mul(position.collateral_amount, collateral_price as u128);
    let borrow_value = math::q64_64_mul(position.borrow_principal, borrow_price as u128);

    calculate_health_factor(
        collateral_value,
        borrow_value,
        collateral_market.liquidation_threshold,
    )
}

/// Get supply position principal
public fun supply_principal<T>(position: &SupplyPosition<T>): u64 {
    position.principal
}

/// Get supply position index at deposit
public fun supply_index_at_deposit<T>(position: &SupplyPosition<T>): u128 {
    position.index_at_deposit
}

/// Get borrow position collateral amount
public fun position_collateral_amount<Collateral, Borrow>(
    position: &BorrowPosition<Collateral, Borrow>,
): u64 {
    position.collateral_amount
}

/// Get borrow position principal
public fun position_borrow_principal<Collateral, Borrow>(
    position: &BorrowPosition<Collateral, Borrow>,
): u64 {
    position.borrow_principal
}

/// Get mutable reference to collateral balance
public fun position_collateral_balance_mut<Collateral, Borrow>(
    position: &mut BorrowPosition<Collateral, Borrow>,
): &mut Balance<Collateral> {
    &mut position.collateral_balance
}

///Set borrow position collateral amount
public fun set_position_collateral_amount<Collateral, Borrow>(
    position: &mut BorrowPosition<Collateral, Borrow>,
    amount: u64,
) {
    position.collateral_amount = amount
}

/// Set borrow position principal
public fun set_position_borrow_principal<Collateral, Borrow>(
    position: &mut BorrowPosition<Collateral, Borrow>,
    principal: u64,
) {
    position.borrow_principal = principal
}

/// Set liquidation status
public fun set_liquidation_status<Collateral, Borrow>(
    position: &mut BorrowPosition<Collateral, Borrow>,
    status: u8,
) {
    position.liquidation_status = status
}

#[test_only]
public fun create_admin_cap_for_testing(ctx: &mut TxContext) {
    transfer::transfer(MarketAdminCap { id: object::new(ctx) }, tx_context::sender(ctx));
}

// ==================== Error Codes ====================

const E_INVALID_COLLATERAL_FACTOR: u64 = 200;
const E_INVALID_THRESHOLD: u64 = 201;
const E_THRESHOLD_TOO_LOW: u64 = 202;
const E_ZERO_AMOUNT: u64 = 203;
const E_ZERO_COLLATERAL: u64 = 204;
const E_INSUFFICIENT_COLLATERAL: u64 = 205;
const E_INSUFFICIENT_LIQUIDITY: u64 = 206;
const E_INSUFFICIENT_BALANCE: u64 = 207;
const E_UNHEALTHY_POSITION: u64 = 208;
const E_WRONG_MARKET: u64 = 209;

// ==================== P2P Integration Helpers ====================

public fun borrow_position_borrower<C, B>(pos: &BorrowPosition<C, B>): address {
    pos.borrower
}

public fun borrow_position_collateral<C, B>(pos: &BorrowPosition<C, B>): u64 {
    pos.collateral_amount
}

public fun borrow_position_principal<C, B>(pos: &BorrowPosition<C, B>): u64 {
    pos.borrow_principal
}

/// Withdraw collateral if debt is zero (used for P2P migration)
public fun withdraw_collateral<C, B>(pos: &mut BorrowPosition<C, B>, ctx: &mut TxContext): Coin<C> {
    assert!(pos.borrow_principal == 0, E_UNHEALTHY_POSITION); // Must be fully repaid
    let amount = pos.collateral_amount;
    pos.collateral_amount = 0;
    coin::from_balance(balance::split(&mut pos.collateral_balance, amount), ctx)
}

/// Seize collateral for liquidation
public fun seize_collateral<C, B>(
    pos: &mut BorrowPosition<C, B>,
    amount: u64,
    ctx: &mut TxContext,
): Coin<C> {
    assert!(amount <= pos.collateral_amount, E_INSUFFICIENT_COLLATERAL);
    pos.collateral_amount = pos.collateral_amount - amount;
    coin::from_balance(balance::split(&mut pos.collateral_balance, amount), ctx)
}
