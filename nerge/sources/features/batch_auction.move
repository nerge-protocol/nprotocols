module protocol::batch_auction;

use acl_dex_core::pool::{Self, Pool};
use nerge_math_lib::math;
use sui::balance::{Self, Balance};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::event;

// ==================== Constants ====================

const BATCH_DURATION_MS: u64 = 2500; // 2.5 seconds
const MAX_ORDERS_PER_BATCH: u64 = 200;

// ==================== Structs ====================

/// Batch auction coordinator
public struct BatchAuction<phantom X, phantom Y> has key {
    id: UID,
    pool_id: ID,
    current_batch_id: u64,
    batch_start_time: u64,
    pending_orders: vector<Order<X, Y>>,
}

/// Individual swap order
public struct Order<phantom X, phantom Y> has store {
    trader: address,
    amount_in: u64,
    min_amount_out: u64,
    max_slippage_bps: u64,
    balance_in: Balance<X>,
    is_x_to_y: bool,
    timestamp: u64,
}

/// Order receipt given to user
public struct OrderReceipt<phantom X, phantom Y> has key, store {
    id: UID,
    batch_id: u64,
    order_index: u64,
    amount_in: u64,
    is_x_to_y: bool,
}

// ==================== Events ====================

public struct OrderSubmitted<phantom X, phantom Y> has copy, drop {
    batch_id: u64,
    trader: address,
    amount_in: u64,
    is_x_to_y: bool,
}

public struct BatchExecuted<phantom X, phantom Y> has copy, drop {
    batch_id: u64,
    clearing_price: u128, // Q64.64
    total_volume_x: u64,
    total_volume_y: u64,
    orders_filled: u64,
}

// ==================== Core Functions ====================

/// Create a new batch auction for a pool
public entry fun create_auction<X, Y>(pool_id: ID, clock: &Clock, ctx: &mut TxContext) {
    let auction = BatchAuction<X, Y> {
        id: object::new(ctx),
        pool_id,
        current_batch_id: 0,
        batch_start_time: clock::timestamp_ms(clock),
        pending_orders: vector::empty(),
    };

    transfer::share_object(auction);
}

/// Submit order to batch
public fun submit_order<X, Y>(
    auction: &mut BatchAuction<X, Y>,
    coin_in: Coin<X>,
    min_amount_out: u64,
    max_slippage_bps: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): OrderReceipt<X, Y> {
    assert!(vector::length(&auction.pending_orders) < MAX_ORDERS_PER_BATCH, E_BATCH_FULL);

    let amount_in = coin::value(&coin_in);
    let current_time = clock::timestamp_ms(clock);

    let order = Order<X, Y> {
        trader: tx_context::sender(ctx),
        amount_in,
        min_amount_out,
        max_slippage_bps,
        balance_in: coin::into_balance(coin_in),
        is_x_to_y: true,
        timestamp: current_time,
    };

    vector::push_back(&mut auction.pending_orders, order);

    let order_index = vector::length(&auction.pending_orders) - 1;

    event::emit(OrderSubmitted<X, Y> {
        batch_id: auction.current_batch_id,
        trader: tx_context::sender(ctx),
        amount_in,
        is_x_to_y: true,
    });

    OrderReceipt<X, Y> {
        id: object::new(ctx),
        batch_id: auction.current_batch_id,
        order_index,
        amount_in,
        is_x_to_y: true,
    }
}

/// Execute batch (anyone can call after batch duration)
public entry fun execute_batch<X, Y>(
    auction: &mut BatchAuction<X, Y>,
    pool: &mut Pool<X, Y>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let current_time = clock::timestamp_ms(clock);
    assert!(current_time >= auction.batch_start_time + BATCH_DURATION_MS, E_BATCH_NOT_READY);

    if (vector::is_empty(&auction.pending_orders)) {
        // No orders, reset batch
        auction.current_batch_id = auction.current_batch_id + 1;
        auction.batch_start_time = current_time;
        return
    };

    // Calculate clearing price (simplified - actual implementation would use optimization)
    let (total_in, total_out_expected) = calculate_batch_totals(&auction.pending_orders);
    let clearing_price = math::to_q64_64(total_out_expected, total_in);

    // Execute all orders at clearing price
    let mut orders_filled = 0u64;

    // Process orders in reverse to efficiently remove from vector
    while (!vector::is_empty(&auction.pending_orders)) {
        let Order {
            trader,
            amount_in,
            min_amount_out,
            max_slippage_bps: _,
            balance_in,
            is_x_to_y: _,
            timestamp: _,
        } = vector::pop_back(&mut auction.pending_orders);

        // Check if order can be filled at clearing price
        let amount_out = math::from_q64_64_mul(clearing_price, amount_in);

        if (amount_out >= min_amount_out) {
            // Execute order by converting balance to coin and swapping
            let coin_in = coin::from_balance(balance_in, ctx);
            let coin_out = pool::swap_exact_input(pool, coin_in, min_amount_out, ctx);

            // Transfer output to trader
            transfer::public_transfer(coin_out, trader);
            orders_filled = orders_filled + 1;
        } else {
            // Order cannot be filled, refund the input
            let coin_refund = coin::from_balance(balance_in, ctx);
            transfer::public_transfer(coin_refund, trader);
        };
    };

    event::emit(BatchExecuted<X, Y> {
        batch_id: auction.current_batch_id,
        clearing_price,
        total_volume_x: total_in,
        total_volume_y: total_out_expected,
        orders_filled,
    });

    // Batch is now empty, increment counters
    auction.current_batch_id = auction.current_batch_id + 1;
    auction.batch_start_time = current_time;
}

// ==================== Helper Functions ====================

fun calculate_batch_totals<X, Y>(orders: &vector<Order<X, Y>>): (u64, u64) {
    let mut total_in = 0u64;
    let mut total_out = 0u64;
    let mut i = 0;

    while (i < vector::length(orders)) {
        let order = vector::borrow(orders, i);
        total_in = total_in + order.amount_in;
        total_out = total_out + order.min_amount_out;
        i = i + 1;
    };

    (total_in, total_out)
}

// ==================== Batch Auction Error Codes ====================
const E_BATCH_FULL: u64 = 100;
const E_BATCH_NOT_READY: u64 = 101;
