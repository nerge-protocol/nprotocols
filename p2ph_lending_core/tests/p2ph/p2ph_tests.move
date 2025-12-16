#[test_only]
module p2ph_lending_core::p2ph_tests;

use nerge_oracle::nerge_oracle::{Self as oracle, PriceFeed};
use p2ph_lending_core::lending_market::{Self, LendingMarket};
use p2ph_lending_core::p2p_auction::{Self, P2PAuction};
use p2ph_lending_core::p2ph_lending::{Self, ProtocolState, AdminCap};
use p2ph_lending_core::rl_oracle::{Self, RLOracle};
use std::option;
use std::vector;
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::object::{Self, UID, ID};
use sui::sui::SUI;
use sui::test_scenario::{Self, Scenario};
use sui::transfer;

// Test coins
public struct USDC has drop {}
public struct ETH has drop {}

// Constants
const ADMIN: address = @0xAD;
const BORROWER: address = @0xB0;
const LENDER: address = @0x1E;

// Setup helpers
fun setup_test(ctx: &mut TxContext): (PriceFeed, RLOracle) {
    let price_feed = oracle::create_price_feed_for_testing(ctx);
    let rl_oracle = rl_oracle::create_for_testing(ctx);
    (price_feed, rl_oracle)
}

#[test]
fun test_p2ph_borrow_trigger() {
    let mut scenario_val = test_scenario::begin(ADMIN);
    let scenario = &mut scenario_val;
    let clock = clock::create_for_testing(test_scenario::ctx(scenario));

    // 1. Initialize Protocol
    test_scenario::next_tx(scenario, ADMIN);
    {
        let ctx = test_scenario::ctx(scenario);
        let (price_feed, rl_oracle) = setup_test(ctx);

        p2ph_lending::init_for_testing(ctx); // Creates AdminCap

        // Share objects
        oracle::share_price_feed_for_testing(price_feed);
        rl_oracle::share_for_testing(rl_oracle);
    };

    // 2. Initialize Lending State
    test_scenario::next_tx(scenario, ADMIN);
    {
        let admin_cap = test_scenario::take_from_sender<AdminCap>(scenario);
        let rl_oracle = test_scenario::take_shared<RLOracle>(scenario);
        let ctx = test_scenario::ctx(scenario);

        p2ph_lending::initialize_protocol<USDC>(
            &admin_cap,
            object::id(&rl_oracle),
            &clock,
            ctx,
        );

        test_scenario::return_to_sender(scenario, admin_cap);
        test_scenario::return_shared(rl_oracle);
    };

    // 3a. Register Oracle
    test_scenario::next_tx(scenario, ADMIN);
    {
        let mut price_feed = test_scenario::take_shared<PriceFeed>(scenario);
        oracle::register_oracle(&mut price_feed, test_scenario::ctx(scenario));
        test_scenario::return_shared(price_feed);
    };

    // 3b. Submit Price
    test_scenario::next_tx(scenario, ADMIN);
    {
        let mut price_feed = test_scenario::take_shared<PriceFeed>(scenario);
        let registration = test_scenario::take_from_sender<oracle::OracleRegistration>(scenario);

        // Submit $1.00 price (Q64.64)
        let price = 18446744073709551616;
        oracle::submit_price(
            &mut price_feed,
            &registration,
            price,
            10000, // High confidence
            &clock,
            test_scenario::ctx(scenario),
        );

        test_scenario::return_to_sender(scenario, registration);
        test_scenario::return_shared(price_feed);
    };

    // 3c. Initialize Lending Market Admin
    test_scenario::next_tx(scenario, ADMIN);
    {
        lending_market::init_for_testing(test_scenario::ctx(scenario));
    };

    // 3d. Create Markets
    test_scenario::next_tx(scenario, ADMIN);
    {
        let market_cap = test_scenario::take_from_sender<lending_market::MarketAdminCap>(scenario);
        let price_feed = test_scenario::take_shared<PriceFeed>(scenario); // Read-only is enough for ID? No, create_market takes ID.
        // But wait, create_market takes `oracle_feed_id: ID`. We don't need the object itself if we have ID.
        // But to get ID we need object or stored ID.
        // Let's take shared just to get ID.

        // Create USDC Market
        lending_market::create_market<USDC>(
            &market_cap,
            8000, // 80% LTV
            8500, // 85% Liquidation Threshold
            500, // 5% Liquidation Penalty
            1000, // 10% Reserve Factor
            2000000, // 2% Base Rate (scaled 1e8)
            10000000, // 10% Multiplier (scaled 1e8)
            50000000, // 50% Jump Multiplier (scaled 1e8)
            8500, // 85% Optimal Utilization (scaled 1e4)
            object::id(&price_feed),
            &clock,
            test_scenario::ctx(scenario),
        );

        // Create ETH Market
        lending_market::create_market<ETH>(
            &market_cap,
            8000, // 80% LTV
            8500, // 85% Liquidation Threshold
            500, // 5% Liquidation Penalty
            1000, // 10% Reserve Factor
            2000000, // 2% Base Rate (scaled 1e8)
            10000000, // 10% Multiplier (scaled 1e8)
            50000000, // 50% Jump Multiplier (scaled 1e8)
            8500, // 85% Optimal Utilization (scaled 1e4)
            object::id(&price_feed),
            &clock,
            test_scenario::ctx(scenario),
        );

        test_scenario::return_to_sender(scenario, market_cap);
        test_scenario::return_shared(price_feed);
    };

    // 4. Supply Liquidity (USDC)
    test_scenario::next_tx(scenario, LENDER);
    {
        let mut market = test_scenario::take_shared<LendingMarket<USDC>>(scenario);

        let coin = coin::mint_for_testing<USDC>(1000000000, test_scenario::ctx(scenario)); // 1000 USDC
        let position = lending_market::supply(
            &mut market,
            coin,
            &clock,
            test_scenario::ctx(scenario),
        );

        transfer::public_transfer(position, LENDER);
        test_scenario::return_shared(market);
    };

    // 5. Borrow with High Risk (Trigger P2P)
    test_scenario::next_tx(scenario, BORROWER);
    {
        let mut protocol = test_scenario::take_shared<ProtocolState<USDC>>(scenario);
        let mut usdc_market = test_scenario::take_shared<LendingMarket<USDC>>(scenario);
        let eth_market = test_scenario::take_shared<LendingMarket<ETH>>(scenario);
        let oracle = test_scenario::take_shared<PriceFeed>(scenario);
        let ctx = test_scenario::ctx(scenario);

        // Collateral: 1000 ETH (Price 1.0)
        // Borrow: 800 USDC (Price 1.0) -> 80% LTV
        // Volatility: High (160%) -> Should trigger P2P

        let collateral = coin::mint_for_testing<ETH>(1000000000, ctx);
        let borrow_amount = 800000000;
        let volatility = 16000; // 160% (High)
        let utilization = 9000; // 90% (High)

        // Set high volatility and utilization to trigger P2P
        p2ph_lending::set_volatility_for_testing(&mut protocol, volatility);
        p2ph_lending::set_utilization_for_testing(&mut protocol, utilization);

        let (position, borrowed_coin) = p2ph_lending::borrow_with_risk(
            &mut protocol,
            &eth_market, // Collateral market
            &mut usdc_market, // Borrow market
            collateral,
            borrow_amount,
            &oracle,
            &clock,
            ctx,
        );

        transfer::public_transfer(position, BORROWER);
        transfer::public_transfer(borrowed_coin, BORROWER);

        test_scenario::return_shared(protocol);
        test_scenario::return_shared(usdc_market);
        test_scenario::return_shared(eth_market);
        test_scenario::return_shared(oracle);
    };

    // 6. Verify Auction Created
    test_scenario::next_tx(scenario, BORROWER);
    {
        // Check if P2PAuction exists
        // Note: P2PAuction<Collateral, Borrow> -> P2PAuction<ETH, USDC>
        let auction = test_scenario::take_shared<P2PAuction<ETH, USDC>>(scenario);

        // Verify properties (optional)

        test_scenario::return_shared(auction);
    };

    clock::destroy_for_testing(clock);
    test_scenario::end(scenario_val);
}
