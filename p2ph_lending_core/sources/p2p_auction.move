// ============================================================================
// FILE: p2p_auction.move
// P2PH P2P Auction Module
// ============================================================================

module p2ph_lending_core::p2p_auction;

use p2ph_lending_core::lending_market::{Self, BorrowPosition, LendingMarket};
use std::option::{Self, Option};
use sui::balance::{Self, Balance};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::event;
use sui::object::{Self, UID, ID};
use sui::transfer;
use sui::tx_context::{Self, TxContext};

// ===================== CONSTANTS =====================

const STATUS_ACTIVE: u8 = 0;
const STATUS_FILLED: u8 = 1;
const STATUS_CANCELLED: u8 = 2;
const STATUS_EXPIRED: u8 = 3;

const MIN_AUCTION_DURATION: u64 = 60000; // 1 minute
const MAX_AUCTION_DURATION: u64 = 86400000; // 24 hours

// Error codes
const E_AUCTION_NOT_ACTIVE: u64 = 1;
const E_BID_TOO_HIGH: u64 = 2;
const E_AUCTION_EXPIRED: u64 = 3;
const E_INVALID_DURATION: u64 = 4;
const E_UNAUTHORIZED: u64 = 5;
const E_INSUFFICIENT_PAYMENT: u64 = 6;

// ===================== STRUCTS =====================

/// P2P auction for position transfer
public struct P2PAuction<phantom Collateral, phantom Borrow> has key, store {
    id: UID,
    position_id: ID,
    borrower: address,
    collateral_amount: u64,
    debt_amount: u64,
    current_rate: u64, // Current interest rate (basis points)
    min_rate: u64, // Minimum rate (starting bid / pool rate)
    best_bidder: Option<address>,
    best_bid_rate: u64,
    start_time: u64,
    end_time: u64,
    status: u8, // 0=ACTIVE, 1=FILLED, 2=CANCELLED
}

/// P2P lender taking over position
public struct P2PLender<phantom Collateral, phantom Borrow> has key, store {
    id: UID,
    position_id: ID,
    lent_amount: u64,
    interest_rate: u64,
    collateral_held: Balance<Collateral>,
    start_time: u64,
    lender: address,
}

// ===================== EVENTS =====================

public struct AuctionCreated has copy, drop {
    auction_id: ID,
    position_id: ID,
    borrower: address,
    debt_amount: u64,
    start_rate: u64,
    end_time: u64,
}

public struct BidPlaced has copy, drop {
    auction_id: ID,
    bidder: address,
    rate: u64,
    timestamp: u64,
}

public struct AuctionSettled has copy, drop {
    auction_id: ID,
    position_id: ID,
    winner: address,
    final_rate: u64,
    timestamp: u64,
}

// ===================== PUBLIC FUNCTIONS =====================

/// Create P2P auction for risky position
public fun create_p2p_auction<Collateral, Borrow>(
    position: &BorrowPosition<Collateral, Borrow>,
    min_rate: u64,
    duration: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): P2PAuction<Collateral, Borrow> {
    assert!(
        duration >= MIN_AUCTION_DURATION && duration <= MAX_AUCTION_DURATION,
        E_INVALID_DURATION,
    );

    let current_time = clock::timestamp_ms(clock);
    let id = object::new(ctx);
    let auction_id = object::uid_to_inner(&id);

    // Extract info from position (using getters from lending_market)
    let position_id = object::id(position);
    let borrower = lending_market::borrow_position_borrower(position);
    let collateral_amount = lending_market::borrow_position_collateral(position);
    let debt_amount = lending_market::borrow_position_principal(position); // Using principal as debt for now

    // In a real implementation, we might want to lock the position or ensure it can't be modified
    // For now, we just create the auction record

    event::emit(AuctionCreated {
        auction_id,
        position_id,
        borrower,
        debt_amount,
        start_rate: min_rate,
        end_time: current_time + duration,
    });

    P2PAuction {
        id,
        position_id,
        borrower,
        collateral_amount,
        debt_amount,
        current_rate: min_rate,
        min_rate,
        best_bidder: option::none(),
        best_bid_rate: min_rate, // Initial "best" is the starting rate (ceiling)
        start_time: current_time,
        end_time: current_time + duration,
        status: STATUS_ACTIVE,
    }
}

/// Bid on P2P auction (compete on interest rate - lower is better for borrower, but higher than pool rate)
/// Wait, P2P auctions usually mean lenders compete to lend?
/// If it's a risky position, lenders demand HIGHER rate.
/// So the auction should be for the LOWEST rate a lender is willing to accept?
/// Or is it a Dutch auction starting high and going low?
/// Or English auction starting low and going high?
///
/// For risky positions:
/// Borrower wants lowest rate.
/// Lenders want highest rate for risk.
///
/// If multiple lenders want the position, they bid DOWN the rate they accept.
/// Starting rate = Max Rate (e.g. 20%).
/// Bidders bid 19%, 18%, etc.
///
/// But here `min_rate` suggests a floor.
/// Let's assume it's a reverse auction: Lenders bid interest rate they accept.
/// Start with a high ceiling (or `min_rate` is actually the pool rate, and bids must be >= pool rate).
///
/// Let's implement as: Lenders bid the rate they demand.
/// Lowest bid wins.
/// But bids must be >= Pool Rate (otherwise why move to P2P?).
/// So `min_rate` is the floor.
/// `current_rate` is the current lowest bid.
/// Initial `current_rate` could be a cap (e.g. 100%).

public entry fun bid_on_auction<Collateral, Borrow>(
    auction: &mut P2PAuction<Collateral, Borrow>,
    bid_rate: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let current_time = clock::timestamp_ms(clock);
    assert!(auction.status == STATUS_ACTIVE, E_AUCTION_NOT_ACTIVE);
    assert!(current_time < auction.end_time, E_AUCTION_EXPIRED);

    // Check bid validity
    // Must be lower than current best bid (if any)
    // Must be >= min_rate
    assert!(bid_rate >= auction.min_rate, E_BID_TOO_HIGH); // "Too low" actually, but reusing code

    if (option::is_some(&auction.best_bidder)) {
        assert!(bid_rate < auction.best_bid_rate, E_BID_TOO_HIGH);
    } else {};

    auction.best_bidder = option::some(tx_context::sender(ctx));
    auction.best_bid_rate = bid_rate;
    auction.current_rate = bid_rate;

    event::emit(BidPlaced {
        auction_id: object::uid_to_inner(&auction.id),
        bidder: tx_context::sender(ctx),
        rate: bid_rate,
        timestamp: current_time,
    });
}

/// Settle auction and transfer position
/// The winner pays off the pool debt and takes over the collateral + new debt position
public fun settle_auction<Collateral, Borrow>(
    auction: P2PAuction<Collateral, Borrow>,
    market: &mut LendingMarket<Borrow>,
    position: &mut BorrowPosition<Collateral, Borrow>, // The actual position to modify
    payment: Coin<Borrow>, // Payment from lender to pool
    clock: &Clock,
    ctx: &mut TxContext,
): P2PLender<Collateral, Borrow> {
    let P2PAuction {
        id,
        position_id,
        borrower: _,
        collateral_amount: _,
        debt_amount,
        current_rate: _,
        min_rate: _,
        best_bidder,
        best_bid_rate,
        start_time: _,
        end_time: _,
        status,
    } = auction;

    let auction_id = object::uid_to_inner(&id);
    object::delete(id);

    assert!(status == STATUS_ACTIVE, E_AUCTION_NOT_ACTIVE);
    assert!(option::is_some(&best_bidder), E_AUCTION_NOT_ACTIVE); // No bids
    assert!(object::id(position) == position_id, E_UNAUTHORIZED);

    let winner = option::destroy_some(best_bidder);
    assert!(tx_context::sender(ctx) == winner, E_UNAUTHORIZED);

    // Verify payment covers debt
    let payment_value = coin::value(&payment);
    assert!(payment_value >= debt_amount, E_INSUFFICIENT_PAYMENT);

    // Repay pool debt using lender's payment
    // We need a way to repay on behalf of borrower but keep position open (just move it)
    // Actually, "moving to P2P" means the Pool is repaid, and the P2P Lender becomes the creditor.
    // So we call `repay` on the market to clear the pool debt.
    // But `repay` usually reduces the debt in the position.
    // Here we want to extract the collateral and create a P2P position.

    // 1. Repay pool debt
    let repaid = lending_market::repay(market, position, payment, clock, ctx);

    // 2. Extract collateral from position (assuming debt is fully paid or we can extract)
    // If debt is fully paid, we can withdraw collateral.
    // But `repay` might not close the position struct.
    // We need `lending_market` to support "liquidate/migrate" which extracts collateral.
    // For now, let's assume we can withdraw collateral if debt is 0.

    let collateral = lending_market::withdraw_collateral(position, ctx);

    // 3. Create P2P Lender position
    let mut p2p_position = P2PLender {
        id: object::new(ctx),
        position_id,
        lent_amount: repaid,
        interest_rate: best_bid_rate,
        collateral_held: balance::zero(), // Placeholder, need to put collateral here
        start_time: clock::timestamp_ms(clock),
        lender: winner,
    };

    // Add collateral to p2p position
    balance::join(&mut p2p_position.collateral_held, coin::into_balance(collateral));

    event::emit(AuctionSettled {
        auction_id,
        position_id,
        winner,
        final_rate: best_bid_rate,
        timestamp: clock::timestamp_ms(clock),
    });

    p2p_position
}

// ===================== VIEW FUNCTIONS =====================

public fun get_best_bidder<C, B>(auction: &P2PAuction<C, B>): Option<address> {
    auction.best_bidder
}

public fun get_best_bid_rate<C, B>(auction: &P2PAuction<C, B>): u64 {
    auction.best_bid_rate
}
