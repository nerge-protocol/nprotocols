module protocol::auction;

use acl_dex_core::pool::{Self as pool, Pool};
use nerge_math_lib::math;
use sui::balance::{Self, Balance};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::object::{Self, UID};
use sui::table::{Self, Table};
use sui::tx_context::{Self, TxContext};

// ==================== Errors ====================

const E_AUCTION_NOT_OPEN: u64 = 1;
const E_AUCTION_CLOSED: u64 = 2;
const E_ORDER_NOT_FOUND: u64 = 3;
const E_UNAUTHORIZED: u64 = 4;

// ==================== Structs ====================

/// Represents a single user order in a batch
public struct Order has drop, store {
    id: u64,
    owner: address,
    /// Amount of token being sold
    amount_in: u64,
    /// Minimum amount of token to receive
    min_amount_out: u64,
    /// True if selling X for Y, False if selling Y for X
    is_bid: bool,
    /// Timestamp when order was placed
    timestamp: u64,
}

/// The Auction House manages batches of orders
public struct AuctionHouse<phantom X, phantom Y> has key {
    id: UID,
    /// Current batch ID
    current_batch_id: u64,
    /// Duration of each batch in milliseconds
    batch_duration_ms: u64,
    /// Timestamp when current batch started
    last_batch_start_time: u64,
    /// Pending orders for the current batch
    /// We use a Table or Bag. Since we need to iterate to clear, a Vector might be better if size is small,
    /// but for scalability, we might need a more complex structure.
    /// For MVP, let's use a Table with an index counter.
    orders: Table<u64, Order>,
    order_count: u64,
    /// Escrowed funds for the current batch
    balance_x: Balance<X>,
    balance_y: Balance<Y>,
}

// ==================== Public Functions ====================

/// Create a new Auction House
public fun create_auction_house<X, Y>(batch_duration_ms: u64, clock: &Clock, ctx: &mut TxContext) {
    let house = AuctionHouse<X, Y> {
        id: object::new(ctx),
        current_batch_id: 0,
        batch_duration_ms,
        last_batch_start_time: clock::timestamp_ms(clock),
        orders: table::new(ctx),
        order_count: 0,
        balance_x: balance::zero(),
        balance_y: balance::zero(),
    };

    sui::transfer::share_object(house);
}

/// Place an order into the current batch
public fun place_order<X, Y>(
    house: &mut AuctionHouse<X, Y>,
    coin_in: Coin<X>, // Assuming X for now, need generic handling for Y
    min_amount_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Note: This function signature assumes selling X.
    // To support selling Y, we need either separate functions or a generic `Coin<T>` where T is X or Y.
    // Move doesn't support "T is X or Y" easily without dynamic dispatch or separate entry points.
    // For simplicity, let's assume this is `place_bid` (Sell X -> Buy Y).

    let amount = coin::value(&coin_in);
    balance::join(&mut house.balance_x, coin::into_balance(coin_in));

    let order = Order {
        id: house.order_count,
        owner: tx_context::sender(ctx),
        amount_in: amount,
        min_amount_out,
        is_bid: true, // Selling X
        timestamp: clock::timestamp_ms(clock),
    };

    table::add(&mut house.orders, house.order_count, order);
    house.order_count = house.order_count + 1;
}

/// Place an ask (Sell Y -> Buy X)
public fun place_ask<X, Y>(
    house: &mut AuctionHouse<X, Y>,
    coin_in: Coin<Y>,
    min_amount_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let amount = coin::value(&coin_in);
    balance::join(&mut house.balance_y, coin::into_balance(coin_in));

    let order = Order {
        id: house.order_count,
        owner: tx_context::sender(ctx),
        amount_in: amount,
        min_amount_out,
        is_bid: false, // Selling Y
        timestamp: clock::timestamp_ms(clock),
    };

    table::add(&mut house.orders, house.order_count, order);
    house.order_count = house.order_count + 1;
}

/// Cancel an order
public fun cancel_order<X, Y>(house: &mut AuctionHouse<X, Y>, order_id: u64, ctx: &mut TxContext) {
    assert!(table::contains(&house.orders, order_id), E_ORDER_NOT_FOUND);

    // We can't easily borrow_mut to check owner and then remove, because remove takes the value.
    // So we remove first, check owner, and if wrong, put it back? No, that changes order.
    // Or we borrow, check, then remove.

    let owner = table::borrow(&house.orders, order_id).owner;
    assert!(owner == tx_context::sender(ctx), E_UNAUTHORIZED);

    let order = table::remove(&mut house.orders, order_id);

    // Refund
    if (order.is_bid) {
        // Was selling X
        let coin_x = coin::take(&mut house.balance_x, order.amount_in, ctx);
        sui::transfer::public_transfer(coin_x, owner);
    } else {
        // Was selling Y
        let coin_y = coin::take(&mut house.balance_y, order.amount_in, ctx);
        sui::transfer::public_transfer(coin_y, owner);
    };
}

/// Execute the current batch
/// Aggregates all orders, calculates net surplus, swaps against pool, and distributes proceeds.
/// For MVP, we assume all orders are "Market Orders" (min_out = 0) to simplify clearing.
public fun execute_batch<X, Y>(
    house: &mut AuctionHouse<X, Y>,
    pool: &mut Pool<X, Y>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // 1. Price Discovery (Iterative)
    // We need to find a Clearing Price P such that:
    // - The set of valid orders (Limit respected at P)
    // - Plus the Pool Swap of the Net Surplus
    // - Results in a realized price equal to P.

    // let sqrt_price_x96 = pool.get_sqrt_price();
    let (sqrt_price_x96, _, _) = pool.get_slot0();
    // Convert Q96 sqrt_price to Q64 price
    // P = (sqrt_price / 2^32)^2 (approx via shift)
    // precise: P = (sqrt_price * sqrt_price) >> 128
    // We'll use a simplified version: P = (sqrt_price >> 32)^2 >> 64 = (sqrt_price >> 32) * (sqrt_price >> 32) / 2^64
    // Better: use math library if available, but manual calc for now:
    // Q96 to Q64:
    // val_q64 = ((val_u256 >> 48) * (val_u256 >> 48)) >> 32 ?
    // No. Q96 * Q96 = Q192. We want Q64. Shift right by 128.
    // clearing_price = (sqrt_price * sqrt_price) >> 128
    let clearing_price_q64 = (((sqrt_price_x96 as u128) >> 64) * ((sqrt_price_x96 as u128) >> 64)); // Rough approx for MVP, safer to implement proper math later

    let mut valid_x_in = 0u64;
    let mut valid_y_in = 0u64;
    let mut net_swap_amount = 0u64;
    let mut net_swap_x_to_y = true;

    let mut iteration = 0;
    while (iteration < 3) {
        valid_x_in = 0;
        valid_y_in = 0;

        // A. Aggregate Valid Orders at current clearing_price
        let mut k = 0;
        while (k < house.order_count) {
            if (table::contains(&house.orders, k)) {
                let order = table::borrow(&house.orders, k);
                let is_valid = if (order.is_bid) {
                    // Selling X. Wants Y >= Min.
                    // Y_out = X_in * P.
                    let expected_out = nerge_math_lib::math::q64_64_mul_u64(
                        clearing_price_q64,
                        order.amount_in,
                    );
                    expected_out >= order.min_amount_out
                } else {
                    // Selling Y. Wants X >= Min.
                    // X_out = Y_in / P.
                    let expected_out = nerge_math_lib::math::q64_64_div(
                        (order.amount_in as u128) * nerge_math_lib::math::one_q64_64(),
                        clearing_price_q64,
                    );
                    (expected_out as u64) >= order.min_amount_out
                };

                if (is_valid) {
                    if (order.is_bid) {
                        valid_x_in = valid_x_in + order.amount_in;
                    } else {
                        valid_y_in = valid_y_in + order.amount_in;
                    };
                };
            };
            k = k + 1;
        };

        if (valid_x_in == 0 && valid_y_in == 0) break;

        // B. Calculate Net Surplus
        // Value of Valid X in Y
        let x_value_in_y = nerge_math_lib::math::q64_64_mul_u64(clearing_price_q64, valid_x_in);

        if (x_value_in_y > valid_y_in) {
            // Surplus X. Swap X -> Y.
            net_swap_x_to_y = true;
            // Surplus X = Total X - (Total Y / P)
            let y_value_in_x = nerge_math_lib::math::q64_64_div(
                (valid_y_in as u128) * nerge_math_lib::math::one_q64_64(),
                clearing_price_q64,
            );
            net_swap_amount = if (valid_x_in > (y_value_in_x as u64)) {
                valid_x_in - (y_value_in_x as u64)
            } else { 0 };
        } else {
            // Surplus Y. Swap Y -> X.
            net_swap_x_to_y = false;
            net_swap_amount = valid_y_in - x_value_in_y;
        };

        iteration = iteration + 1;
    };

    // 2. Execute with Final Valid Set
    if (valid_x_in == 0 && valid_y_in == 0) return;

    let (swap_x_to_y, swap_amount) = (net_swap_x_to_y, net_swap_amount);

    // 3. Execute Swap
    if (swap_amount > 0) {
        if (swap_x_to_y) {
            let coin_in = coin::take(&mut house.balance_x, swap_amount, ctx);
            let coin_out = pool::swap_exact_input(pool, coin_in, 0, ctx); // 0 min_out for now
            balance::join(&mut house.balance_y, coin::into_balance(coin_out));
        } else {
            let coin_in = coin::take(&mut house.balance_y, swap_amount, ctx);
            let coin_out = pool::swap_exact_input_1_for_0(pool, coin_in, 0, ctx);
            balance::join(&mut house.balance_x, coin::into_balance(coin_out));
        };
    };

    // 4. Distribute Proceeds (Clearing)
    // Calculate final clearing prices
    // Price X->Y = Total Y Available / Total X In
    // Price Y->X = Total X Available / Total Y In

    let total_x_available = balance::value(&house.balance_x);
    let total_y_available = balance::value(&house.balance_y);

    // Iterate and settle
    // In a real system, users would "claim" later to avoid O(N) loop here.
    // For MVP, we loop.
    // Iterate and settle
    let mut j = 0;
    while (j < house.order_count) {
        if (table::contains(&house.orders, j)) {
            let order = table::remove(&mut house.orders, j);

            // Re-check validity to decide: Fill or Refund
            // Use the SAME clearing_price_q64 as the aggregation loop
            let is_valid = if (order.is_bid) {
                let expected_out = nerge_math_lib::math::q64_64_mul_u64(
                    clearing_price_q64,
                    order.amount_in,
                );
                expected_out >= order.min_amount_out
            } else {
                let expected_out = nerge_math_lib::math::q64_64_div(
                    (order.amount_in as u128) * nerge_math_lib::math::one_q64_64(),
                    clearing_price_q64,
                );
                (expected_out as u64) >= order.min_amount_out
            };

            if (is_valid) {
                if (order.is_bid) {
                    // Sold X, receives Y
                    let amount_out = nerge_math_lib::math::mul_div(
                        order.amount_in,
                        (total_y_available as u128),
                        (valid_x_in as u128), // Use valid_x_in, not total_x_in
                    );
                    let coin_out = coin::take(&mut house.balance_y, amount_out, ctx);
                    sui::transfer::public_transfer(coin_out, order.owner);
                } else {
                    // Sold Y, receives X
                    let amount_out = nerge_math_lib::math::mul_div(
                        order.amount_in,
                        (total_x_available as u128),
                        (valid_y_in as u128), // Use valid_y_in, not total_y_in
                    );
                    let coin_out = coin::take(&mut house.balance_x, amount_out, ctx);
                    sui::transfer::public_transfer(coin_out, order.owner);
                };
            } else {
                // Refund
                if (order.is_bid) {
                    let coin_refund = coin::take(&mut house.balance_x, order.amount_in, ctx);
                    sui::transfer::public_transfer(coin_refund, order.owner);
                } else {
                    let coin_refund = coin::take(&mut house.balance_y, order.amount_in, ctx);
                    sui::transfer::public_transfer(coin_refund, order.owner);
                };
            };
        };
        j = j + 1;
    };

    // Reset
    house.order_count = 0;
    house.current_batch_id = house.current_batch_id + 1;
    house.last_batch_start_time = clock::timestamp_ms(clock);
}
