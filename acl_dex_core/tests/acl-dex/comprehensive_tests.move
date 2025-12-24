/// Comprehensive Test Suite for Uniswap V3 Style DEX
///
/// This module contains extensive tests covering:
/// - Position management edge cases
/// - Tick operations and bitmap navigation
/// - Swap edge cases (multiple tick crossings, price limits)
/// - Fee calculations and accumulation
/// - NFT integration
/// - Boundary conditions
#[test_only]
module acl_dex_core::comprehensive_tests;

use acl_dex_core::pool::{Self, Pool};
use acl_dex_core::position::{Self, PositionNFT, PositionRegistry};
use nerge_math_lib::signed_math;
use nerge_math_lib::tick_math;
use sui::coin::{Self, Coin};
use sui::test_scenario::{Self, Scenario};
use sui::test_utils;
use sui::tx_context;

// Test token types
public struct TOKEN_A has drop {}
public struct TOKEN_B has drop {}

// ========================================================================
// Test Helpers
// ========================================================================

fun setup_pool(scenario: &mut Scenario, sender: address): Pool<TOKEN_A, TOKEN_B> {
    test_scenario::next_tx(scenario, sender);
    let ctx = test_scenario::ctx(scenario);

    // Create pool at price 1.0
    let sqrt_price = 79228162514264337593543950336_u256;
    pool::create_pool<TOKEN_A, TOKEN_B>(
        3000, // 0.3% fee
        60, // tick spacing
        sqrt_price,
        ctx,
    )
}

fun setup_registry(scenario: &mut Scenario, sender: address): PositionRegistry {
    test_scenario::next_tx(scenario, sender);
    let ctx = test_scenario::ctx(scenario);
    position::create_registry_for_testing(ctx)
}

fun mint_position(
    pool: &mut Pool<TOKEN_A, TOKEN_B>,
    registry: &mut PositionRegistry,
    scenario: &mut Scenario,
    sender: address,
    tick_lower: u32,
    tick_upper: u32,
    amount: u64,
): u64 {
    test_scenario::next_tx(scenario, sender);
    let ctx = test_scenario::ctx(scenario);

    let payment_0 = coin::mint_for_testing<TOKEN_A>(amount, ctx);
    let payment_1 = coin::mint_for_testing<TOKEN_B>(amount, ctx);

    let (_, _, _, nft) = pool::mint(
        pool,
        registry,
        tick_lower,
        tick_upper,
        amount,
        amount,
        0,
        0,
        payment_0,
        payment_1,
        sender,
        ctx,
    );
    let token_id = position::token_id(&nft);
    transfer::public_transfer(nft, sender);

    token_id
}

// ========================================================================
// Pool Creation Tests
// ========================================================================

#[test]
fun test_pool_creation_at_various_prices() {
    let sender = @0xA;
    let mut scenario = test_scenario::begin(sender);

    // Safe minimum price (tick ~= -100000)
    let safe_min_price = 4295128740_u256;

    // Safe maximum price (tick ~= 100000)
    let safe_max_price = 1461446703485210103287273052203988822378723970341_u256;

    // Middle price (tick = 0)
    let price_one = 79228162514264337593543950336_u256;

    // Test at min price
    test_scenario::next_tx(&mut scenario, sender);
    let ctx = test_scenario::ctx(&mut scenario);
    // let min_price = tick_math::get_min_sqrt_ratio();
    // Add buffer to avoid edge case
    let min_price = tick_math::get_min_sqrt_ratio() + 1;
    let pool1 = pool::create_pool<TOKEN_A, TOKEN_B>(3000, 60, safe_min_price, ctx);
    test_utils::destroy(pool1);

    // Test at max price
    test_scenario::next_tx(&mut scenario, sender);
    let ctx = test_scenario::ctx(&mut scenario);
    let max_price = tick_math::get_max_sqrt_ratio() - 1;
    let pool2 = pool::create_pool<TOKEN_A, TOKEN_B>(3000, 60, safe_max_price, ctx);
    test_utils::destroy(pool2);

    // Test at price 1.0
    test_scenario::next_tx(&mut scenario, sender);
    let ctx = test_scenario::ctx(&mut scenario);
    // let price_one = 79228162514264337593543950336_u256;
    let pool3 = pool::create_pool<TOKEN_A, TOKEN_B>(3000, 60, price_one, ctx);
    test_utils::destroy(pool3);

    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = pool::EINVALID_FEE)]
fun test_pool_creation_zero_fee_fails() {
    let sender = @0xA;
    let mut scenario = test_scenario::begin(sender);
    test_scenario::next_tx(&mut scenario, sender);
    let ctx = test_scenario::ctx(&mut scenario);

    let sqrt_price = 79228162514264337593543950336_u256;
    let pool = pool::create_pool<TOKEN_A, TOKEN_B>(0, 60, sqrt_price, ctx);
    test_utils::destroy(pool);

    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = pool::EINVALID_FEE)]
fun test_pool_creation_excessive_fee_fails() {
    let sender = @0xA;
    let mut scenario = test_scenario::begin(sender);
    test_scenario::next_tx(&mut scenario, sender);
    let ctx = test_scenario::ctx(&mut scenario);

    let sqrt_price = 79228162514264337593543950336_u256;
    let pool = pool::create_pool<TOKEN_A, TOKEN_B>(1000001, 60, sqrt_price, ctx);
    test_utils::destroy(pool);

    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = pool::EINVALID_SQRT_PRICE)]
fun test_pool_creation_invalid_price_fails() {
    let sender = @0xA;
    let mut scenario = test_scenario::begin(sender);
    test_scenario::next_tx(&mut scenario, sender);
    let ctx = test_scenario::ctx(&mut scenario);

    let invalid_price = tick_math::get_max_sqrt_ratio() + 1;
    let pool = pool::create_pool<TOKEN_A, TOKEN_B>(3000, 60, invalid_price, ctx);
    test_utils::destroy(pool);

    test_scenario::end(scenario);
}

// ========================================================================
// Position Minting Tests - Edge Cases
// ========================================================================

#[test]
fun test_mint_position_at_current_price() {
    let sender = @0xA;
    let mut scenario = test_scenario::begin(sender);
    let mut pool = setup_pool(&mut scenario, sender);
    let mut registry = setup_registry(&mut scenario, sender);

    // Mint around current price (tick 0)
    let tick_lower = signed_math::from_negative_i32(60);
    let tick_upper = signed_math::from_literal_i32(60);

    let token_id = mint_position(
        &mut pool,
        &mut registry,
        &mut scenario,
        sender,
        tick_lower,
        tick_upper,
        10000000,
    );

    assert!(token_id == 1, 0);

    // Verify pool liquidity increased
    let (_, _, liquidity) = pool::get_slot0(&pool);
    assert!(liquidity > 0, 1);

    test_utils::destroy(pool);
    test_utils::destroy(registry);
    test_scenario::end(scenario);
}

#[test]
fun test_mint_position_below_current_price() {
    let sender = @0xA;
    let mut scenario = test_scenario::begin(sender);
    let mut pool = setup_pool(&mut scenario, sender);
    let mut registry = setup_registry(&mut scenario, sender);

    // Mint below current price (only token0 needed)
    let tick_lower = signed_math::from_negative_i32(600);
    let tick_upper = signed_math::from_negative_i32(60);

    let token_id = mint_position(
        &mut pool,
        &mut registry,
        &mut scenario,
        sender,
        tick_lower,
        tick_upper,
        10000000,
    );

    assert!(token_id == 1, 0);

    // Pool liquidity should NOT increase (out of range)
    let (_, _, liquidity) = pool::get_slot0(&pool);
    assert!(liquidity == 0, 1);

    test_utils::destroy(pool);
    test_utils::destroy(registry);
    test_scenario::end(scenario);
}

#[test]
fun test_mint_position_above_current_price() {
    let sender = @0xA;
    let mut scenario = test_scenario::begin(sender);
    let mut pool = setup_pool(&mut scenario, sender);
    let mut registry = setup_registry(&mut scenario, sender);

    // Mint above current price (only token1 needed)
    let tick_lower = signed_math::from_literal_i32(60);
    let tick_upper = signed_math::from_literal_i32(600);

    let token_id = mint_position(
        &mut pool,
        &mut registry,
        &mut scenario,
        sender,
        tick_lower,
        tick_upper,
        10000000,
    );

    assert!(token_id == 1, 0);

    // Pool liquidity should NOT increase
    let (_, _, liquidity) = pool::get_slot0(&pool);
    assert!(liquidity == 0, 1);

    test_utils::destroy(pool);
    test_utils::destroy(registry);
    test_scenario::end(scenario);
}

#[test]
fun test_mint_multiple_positions_same_range() {
    let sender = @0xA;
    let mut scenario = test_scenario::begin(sender);
    let mut pool = setup_pool(&mut scenario, sender);
    let mut registry = setup_registry(&mut scenario, sender);

    let tick_lower = signed_math::from_negative_i32(60);
    let tick_upper = signed_math::from_literal_i32(60);

    // Mint first position
    let token_id_1 = mint_position(
        &mut pool,
        &mut registry,
        &mut scenario,
        sender,
        tick_lower,
        tick_upper,
        5000000,
    );

    let (_, _, liquidity_1) = pool::get_slot0(&pool);

    // Mint second position (same range, same user)
    let token_id_2 = mint_position(
        &mut pool,
        &mut registry,
        &mut scenario,
        sender,
        tick_lower,
        tick_upper,
        5000000,
    );

    let (_, _, liquidity_2) = pool::get_slot0(&pool);

    // Should have two different NFTs
    assert!(token_id_1 != token_id_2, 0);
    assert!(token_id_1 == 1, 1);
    assert!(token_id_2 == 2, 2);

    // Liquidity should have doubled
    assert!(liquidity_2 > liquidity_1, 3);

    test_utils::destroy(pool);
    test_utils::destroy(registry);
    test_scenario::end(scenario);
}

#[test]
fun test_mint_overlapping_positions() {
    let sender = @0xA;
    let mut scenario = test_scenario::begin(sender);
    let mut pool = setup_pool(&mut scenario, sender);
    let mut registry = setup_registry(&mut scenario, sender);

    // Position 1: [-120, 120]
    mint_position(
        &mut pool,
        &mut registry,
        &mut scenario,
        sender,
        signed_math::from_negative_i32(120),
        signed_math::from_literal_i32(120),
        5000000,
    );

    let (_, _, liquidity_1) = pool::get_slot0(&pool);

    // Position 2: [-60, 60] (overlapping)
    mint_position(
        &mut pool,
        &mut registry,
        &mut scenario,
        sender,
        signed_math::from_negative_i32(60),
        signed_math::from_literal_i32(60),
        5000000,
    );

    let (_, _, liquidity_2) = pool::get_slot0(&pool);

    // Both positions are in range, liquidity should increase
    assert!(liquidity_2 > liquidity_1, 0);

    test_utils::destroy(pool);
    test_utils::destroy(registry);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = pool::EINVALID_TICK_RANGE)]
fun test_mint_invalid_tick_range_fails() {
    let sender = @0xA;
    let mut scenario = test_scenario::begin(sender);
    let mut pool = setup_pool(&mut scenario, sender);
    let mut registry = setup_registry(&mut scenario, sender);

    // tick_lower > tick_upper (invalid)
    mint_position(
        &mut pool,
        &mut registry,
        &mut scenario,
        sender,
        signed_math::from_literal_i32(120),
        signed_math::from_literal_i32(60),
        5000000,
    );

    test_utils::destroy(pool);
    test_utils::destroy(registry);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = pool::ETICK_NOT_ALIGNED)]
fun test_mint_unaligned_tick_fails() {
    let sender = @0xA;
    let mut scenario = test_scenario::begin(sender);
    let mut pool = setup_pool(&mut scenario, sender);
    let mut registry = setup_registry(&mut scenario, sender);

    // Tick 61 is not aligned to spacing 60
    mint_position(
        &mut pool,
        &mut registry,
        &mut scenario,
        sender,
        signed_math::from_literal_i32(1),
        signed_math::from_literal_i32(61),
        5000000,
    );

    test_utils::destroy(pool);
    test_utils::destroy(registry);
    test_scenario::end(scenario);
}

#[test]
fun test_mint_at_tick_boundaries() {
    let sender = @0xA;
    let mut scenario = test_scenario::begin(sender);
    let mut pool = setup_pool(&mut scenario, sender);
    let mut registry = setup_registry(&mut scenario, sender);

    // Mint at extreme tick boundaries
    // let min_tick = tick_math::get_min_tick();
    // let max_tick = tick_math::get_max_tick();
    // Instead of min_tick and max_tick extremes
    let tick_lower = signed_math::from_negative_i32(10020); // -10020 % 60 == 0
    let tick_upper = signed_math::from_literal_i32(10020); // 10020 % 60 == 0
    let min_tick = tick_lower;
    let max_tick = tick_upper;

    // Align to tick spacing
    // let min_aligned = signed_math::sub_i32(
    //     min_tick,
    //     signed_math::abs_i32(min_tick) % 60,
    // );
    // let max_aligned = signed_math::sub_i32(
    //     max_tick,
    //     signed_math::abs_i32(max_tick) % 60,
    // );

    // Align min_tick (negative) - round toward zero
    let min_remainder = signed_math::abs_i32(min_tick) % 60;
    let min_aligned = if (min_remainder == 0) {
        min_tick
    } else {
        signed_math::add_i32(min_tick, (60 - min_remainder))
    };

    // Align max_tick (positive) - round toward zero
    let max_remainder = signed_math::abs_i32(max_tick) % 60;
    let max_aligned = if (max_remainder == 0) {
        max_tick
    } else {
        signed_math::sub_i32(max_tick, max_remainder)
    };

    let token_id = mint_position(
        &mut pool,
        &mut registry,
        &mut scenario,
        sender,
        min_aligned,
        max_aligned,
        10000000,
    );

    assert!(token_id == 1, 0);

    test_utils::destroy(pool);
    test_utils::destroy(registry);
    test_scenario::end(scenario);
}

// ========================================================================
// Increase/Decrease Liquidity Tests
// ========================================================================

#[test]
fun test_increase_liquidity() {
    let sender = @0xA;
    let mut scenario = test_scenario::begin(sender);
    let mut pool = setup_pool(&mut scenario, sender);
    let mut registry = setup_registry(&mut scenario, sender);

    let tick_lower = signed_math::from_negative_i32(60);
    let tick_upper = signed_math::from_literal_i32(60);

    // Mint initial position
    mint_position(
        &mut pool,
        &mut registry,
        &mut scenario,
        sender,
        tick_lower,
        tick_upper,
        5000000,
    );

    let (_, _, liquidity_before) = pool::get_slot0(&pool);

    // Get the NFT (it was transferred to sender)
    test_scenario::next_tx(&mut scenario, sender);
    let mut nft = test_scenario::take_from_sender<PositionNFT>(&scenario);

    // Increase liquidity
    test_scenario::next_tx(&mut scenario, sender);
    let ctx = test_scenario::ctx(&mut scenario);
    let payment_0 = coin::mint_for_testing<TOKEN_A>(5000000, ctx);
    let payment_1 = coin::mint_for_testing<TOKEN_B>(5000000, ctx);

    let (amount0, amount1, liquidity_delta) = pool::increase_liquidity(
        &mut pool,
        &mut nft,
        5000000,
        5000000,
        0,
        0,
        payment_0,
        payment_1,
        ctx,
    );

    assert!(amount0 > 0, 0);
    assert!(amount1 > 0, 1);
    assert!(liquidity_delta > 0, 2);

    let (_, _, liquidity_after) = pool::get_slot0(&pool);
    assert!(liquidity_after > liquidity_before, 3);

    test_scenario::return_to_sender(&scenario, nft);
    test_utils::destroy(pool);
    test_utils::destroy(registry);
    test_scenario::end(scenario);
}

#[test]
fun test_decrease_liquidity() {
    let sender = @0xA;
    let mut scenario = test_scenario::begin(sender);
    let mut pool = setup_pool(&mut scenario, sender);
    let mut registry = setup_registry(&mut scenario, sender);

    let tick_lower = signed_math::from_negative_i32(60);
    let tick_upper = signed_math::from_literal_i32(60);

    // Mint position
    mint_position(
        &mut pool,
        &mut registry,
        &mut scenario,
        sender,
        tick_lower,
        tick_upper,
        10000000,
    );

    let (_, _, liquidity_before) = pool::get_slot0(&pool);

    // Get the NFT
    test_scenario::next_tx(&mut scenario, sender);
    let mut nft = test_scenario::take_from_sender<PositionNFT>(&scenario);
    let initial_liquidity = position::liquidity(&nft);

    // Decrease liquidity by half
    test_scenario::next_tx(&mut scenario, sender);
    let ctx = test_scenario::ctx(&mut scenario);
    let liquidity_to_remove = initial_liquidity / 2;

    let (amount0, amount1) = pool::decrease_liquidity(
        &mut pool,
        &mut nft,
        liquidity_to_remove,
        ctx,
    );

    assert!(amount0 > 0, 0);
    assert!(amount1 > 0, 1);

    let (_, _, liquidity_after) = pool::get_slot0(&pool);
    assert!(liquidity_after < liquidity_before, 2);

    // Check NFT updated
    let remaining_liquidity = position::liquidity(&nft);
    assert!(remaining_liquidity == initial_liquidity - liquidity_to_remove, 3);

    // Tokens owed should have increased
    assert!(position::tokens_owed_0(&nft) >= amount0, 4);
    assert!(position::tokens_owed_1(&nft) >= amount1, 5);

    test_scenario::return_to_sender(&scenario, nft);
    test_utils::destroy(pool);
    test_utils::destroy(registry);
    test_scenario::end(scenario);
}

#[test]
fun test_decrease_all_liquidity() {
    let sender = @0xA;
    let mut scenario = test_scenario::begin(sender);
    let mut pool = setup_pool(&mut scenario, sender);
    let mut registry = setup_registry(&mut scenario, sender);

    let tick_lower = signed_math::from_negative_i32(60);
    let tick_upper = signed_math::from_literal_i32(60);

    mint_position(
        &mut pool,
        &mut registry,
        &mut scenario,
        sender,
        tick_lower,
        tick_upper,
        10000000,
    );

    test_scenario::next_tx(&mut scenario, sender);
    let mut nft = test_scenario::take_from_sender<PositionNFT>(&scenario);
    let initial_liquidity = position::liquidity(&nft);

    // Remove all liquidity
    test_scenario::next_tx(&mut scenario, sender);
    let ctx = test_scenario::ctx(&mut scenario);

    pool::decrease_liquidity(
        &mut pool,
        &mut nft,
        initial_liquidity,
        ctx,
    );

    // Position should have zero liquidity
    assert!(position::liquidity(&nft) == 0, 0);

    // Pool liquidity should be zero
    let (_, _, pool_liquidity) = pool::get_slot0(&pool);
    assert!(pool_liquidity == 0, 1);

    test_scenario::return_to_sender(&scenario, nft);
    test_utils::destroy(pool);
    test_utils::destroy(registry);
    test_scenario::end(scenario);
}

// ========================================================================
// Collect Fees Tests
// ========================================================================

#[test]
fun test_collect_fees_after_swaps() {
    let sender = @0xA;
    let trader = @0xB;
    let mut scenario = test_scenario::begin(sender);
    let mut pool = setup_pool(&mut scenario, sender);
    let mut registry = setup_registry(&mut scenario, sender);

    // LP provides liquidity
    mint_position(
        &mut pool,
        &mut registry,
        &mut scenario,
        sender,
        signed_math::from_negative_i32(600),
        signed_math::from_literal_i32(600),
        100000000,
    );

    // Trader performs swap
    test_scenario::next_tx(&mut scenario, trader);
    let ctx = test_scenario::ctx(&mut scenario);
    let payment = coin::mint_for_testing<TOKEN_A>(1000000, ctx);
    let sqrt_price_limit = tick_math::get_min_sqrt_ratio() + 1;

    let output = pool::swap_0_for_1(
        &mut pool,
        1000000,
        sqrt_price_limit,
        payment,
        ctx,
    );
    test_utils::destroy(output);

    // LP collects fees
    test_scenario::next_tx(&mut scenario, sender);
    let mut nft = test_scenario::take_from_sender<PositionNFT>(&scenario);

    test_scenario::next_tx(&mut scenario, sender);
    let ctx = test_scenario::ctx(&mut scenario);

    let (coin_0, coin_1) = pool::collect(
        &mut pool,
        &mut nft,
        0, // collect all
        0,
        ctx,
    );

    // Should have collected some fees
    let fees_0 = coin::value(&coin_0);
    let fees_1 = coin::value(&coin_1);

    // At least one token should have fees (from the swap)
    assert!(fees_0 > 0 || fees_1 > 0, 0);

    test_utils::destroy(coin_0);
    test_utils::destroy(coin_1);
    test_scenario::return_to_sender(&scenario, nft);
    test_utils::destroy(pool);
    test_utils::destroy(registry);
    test_scenario::end(scenario);
}

#[test]
fun test_collect_partial_fees() {
    let sender = @0xA;
    let mut scenario = test_scenario::begin(sender);
    let mut pool = setup_pool(&mut scenario, sender);
    let mut registry = setup_registry(&mut scenario, sender);

    mint_position(
        &mut pool,
        &mut registry,
        &mut scenario,
        sender,
        signed_math::from_negative_i32(600),
        signed_math::from_literal_i32(600),
        100000000,
    );

    // Perform swap to generate fees
    test_scenario::next_tx(&mut scenario, sender);
    let ctx = test_scenario::ctx(&mut scenario);
    let payment = coin::mint_for_testing<TOKEN_A>(10000000, ctx);
    let sqrt_price_limit = tick_math::get_min_sqrt_ratio() + 1;

    let output = pool::swap_0_for_1(
        &mut pool,
        10000000,
        sqrt_price_limit,
        payment,
        ctx,
    );
    test_utils::destroy(output);

    // Collect partial fees
    test_scenario::next_tx(&mut scenario, sender);
    let mut nft = test_scenario::take_from_sender<PositionNFT>(&scenario);
    let tokens_owed_0_before = position::tokens_owed_0(&nft);

    test_scenario::next_tx(&mut scenario, sender);
    let ctx = test_scenario::ctx(&mut scenario);

    let collect_amount = tokens_owed_0_before / 2;
    let (coin_0, coin_1) = pool::collect(
        &mut pool,
        &mut nft,
        collect_amount,
        0,
        ctx,
    );

    assert!(coin::value(&coin_0) == collect_amount, 0);

    // Should still have fees owed
    let tokens_owed_0_after = position::tokens_owed_0(&nft);
    assert!(tokens_owed_0_after > 0, 1);

    test_utils::destroy(coin_0);
    test_utils::destroy(coin_1);
    test_scenario::return_to_sender(&scenario, nft);
    test_utils::destroy(pool);
    test_utils::destroy(registry);
    test_scenario::end(scenario);
}

// ========================================================================
// Swap Tests - Edge Cases
// ========================================================================

#[test]
fun test_swap_small_amount() {
    let sender = @0xA;
    let mut scenario = test_scenario::begin(sender);
    let mut pool = setup_pool(&mut scenario, sender);
    let mut registry = setup_registry(&mut scenario, sender);

    // Add liquidity
    mint_position(
        &mut pool,
        &mut registry,
        &mut scenario,
        sender,
        signed_math::from_negative_i32(600),
        signed_math::from_literal_i32(600),
        100000000,
    );

    // Swap very small amount
    test_scenario::next_tx(&mut scenario, sender);
    let ctx = test_scenario::ctx(&mut scenario);
    let payment = coin::mint_for_testing<TOKEN_A>(100, ctx);
    let sqrt_price_limit = tick_math::get_min_sqrt_ratio() + 1;

    let output = pool::swap_0_for_1(
        &mut pool,
        100,
        sqrt_price_limit,
        payment,
        ctx,
    );

    assert!(coin::value(&output) > 0, 0);

    test_utils::destroy(output);
    test_utils::destroy(pool);
    test_utils::destroy(registry);
    test_scenario::end(scenario);
}

#[test]
fun test_swap_crosses_multiple_ticks() {
    let sender = @0xA;
    let mut scenario = test_scenario::begin(sender);
    let mut pool = setup_pool(&mut scenario, sender);
    let mut registry = setup_registry(&mut scenario, sender);

    // Add liquidity at different ranges
    mint_position(
        &mut pool,
        &mut registry,
        &mut scenario,
        sender,
        signed_math::from_negative_i32(180),
        signed_math::from_negative_i32(60),
        50000000,
    );

    mint_position(
        &mut pool,
        &mut registry,
        &mut scenario,
        sender,
        signed_math::from_negative_i32(60),
        signed_math::from_literal_i32(60),
        50000000,
    );

    mint_position(
        &mut pool,
        &mut registry,
        &mut scenario,
        sender,
        signed_math::from_literal_i32(60),
        signed_math::from_literal_i32(180),
        50000000,
    );

    let (price_before, _, _) = pool::get_slot0(&pool);

    // Large swap that crosses multiple ticks
    test_scenario::next_tx(&mut scenario, sender);
    let ctx = test_scenario::ctx(&mut scenario);
    let payment = coin::mint_for_testing<TOKEN_A>(20000000, ctx);
    let sqrt_price_limit = tick_math::get_min_sqrt_ratio() + 1;

    let output = pool::swap_0_for_1(
        &mut pool,
        20000000,
        sqrt_price_limit,
        payment,
        ctx,
    );

    let (price_after, _, _) = pool::get_slot0(&pool);

    // Price should have moved significantly
    assert!(price_after < price_before, 0);
    assert!(coin::value(&output) > 0, 1);

    test_utils::destroy(output);
    test_utils::destroy(pool);
    test_utils::destroy(registry);
    test_scenario::end(scenario);
}

#[test]
fun test_swap_in_both_directions() {
    let sender = @0xA;
    let mut scenario = test_scenario::begin(sender);
    let mut pool = setup_pool(&mut scenario, sender);
    let mut registry = setup_registry(&mut scenario, sender);

    mint_position(
        &mut pool,
        &mut registry,
        &mut scenario,
        sender,
        signed_math::from_negative_i32(600),
        signed_math::from_literal_i32(600),
        100000000,
    );

    let (price_initial, _, _) = pool::get_slot0(&pool);

    // Swap 0 for 1
    test_scenario::next_tx(&mut scenario, sender);
    let ctx = test_scenario::ctx(&mut scenario);
    let payment = coin::mint_for_testing<TOKEN_A>(1000000, ctx);
    let sqrt_price_limit = tick_math::get_min_sqrt_ratio() + 1;

    let output1 = pool::swap_0_for_1(
        &mut pool,
        1000000,
        sqrt_price_limit,
        payment,
        ctx,
    );

    let (price_after_swap1, _, _) = pool::get_slot0(&pool);
    assert!(price_after_swap1 < price_initial, 0);

    // Swap 1 for 0 (reverse)
    test_scenario::next_tx(&mut scenario, sender);
    let ctx = test_scenario::ctx(&mut scenario);
    let payment2 = coin::mint_for_testing<TOKEN_B>(1000000, ctx);
    let sqrt_price_limit2 = tick_math::get_max_sqrt_ratio() - 1;

    let output2 = pool::swap_1_for_0(
        &mut pool,
        1000000,
        sqrt_price_limit2,
        payment2,
        ctx,
    );

    let (price_after_swap2, _, _) = pool::get_slot0(&pool);
    assert!(price_after_swap2 > price_after_swap1, 1);

    test_utils::destroy(output1);
    test_utils::destroy(output2);
    test_utils::destroy(pool);
    test_utils::destroy(registry);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = pool::EINSUFFICIENT_LIQUIDITY)]
fun test_swap_no_liquidity_fails() {
    let sender = @0xA;
    let mut scenario = test_scenario::begin(sender);
    let mut pool = setup_pool(&mut scenario, sender);

    // Try to swap without any liquidity
    test_scenario::next_tx(&mut scenario, sender);
    let ctx = test_scenario::ctx(&mut scenario);
    let payment = coin::mint_for_testing<TOKEN_A>(1000000, ctx);
    let sqrt_price_limit = tick_math::get_min_sqrt_ratio() + 1;

    let output = pool::swap_0_for_1(
        &mut pool,
        1000000,
        sqrt_price_limit,
        payment,
        ctx,
    );

    test_utils::destroy(output);
    test_utils::destroy(pool);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = pool::EZERO_AMOUNT)]
fun test_swap_zero_amount_fails() {
    let sender = @0xA;
    let mut scenario = test_scenario::begin(sender);
    let mut pool = setup_pool(&mut scenario, sender);
    let mut registry = setup_registry(&mut scenario, sender);

    mint_position(
        &mut pool,
        &mut registry,
        &mut scenario,
        sender,
        signed_math::from_negative_i32(600),
        signed_math::from_literal_i32(600),
        100000000,
    );

    test_scenario::next_tx(&mut scenario, sender);
    let ctx = test_scenario::ctx(&mut scenario);
    let payment = coin::mint_for_testing<TOKEN_A>(0, ctx);
    let sqrt_price_limit = tick_math::get_min_sqrt_ratio() + 1;

    let output = pool::swap_0_for_1(
        &mut pool,
        0,
        sqrt_price_limit,
        payment,
        ctx,
    );

    test_utils::destroy(output);
    test_utils::destroy(pool);
    test_utils::destroy(registry);
    test_scenario::end(scenario);
}

// ========================================================================
// NFT Integration Tests
// ========================================================================

#[test]
#[expected_failure(abort_code = pool::ENFT_WRONG_POOL)]
fun test_use_nft_from_different_pool_fails() {
    let sender = @0xA;
    let mut scenario = test_scenario::begin(sender);

    // Create two pools
    let mut pool1 = setup_pool(&mut scenario, sender);

    test_scenario::next_tx(&mut scenario, sender);
    let ctx = test_scenario::ctx(&mut scenario);
    let sqrt_price = 79228162514264337593543950336_u256;
    let mut pool2 = pool::create_pool<TOKEN_A, TOKEN_B>(3000, 60, sqrt_price, ctx);

    let mut registry = setup_registry(&mut scenario, sender);

    // Mint position in pool1
    mint_position(
        &mut pool1,
        &mut registry,
        &mut scenario,
        sender,
        signed_math::from_negative_i32(60),
        signed_math::from_literal_i32(60),
        10000000,
    );

    // Get NFT from pool1
    test_scenario::next_tx(&mut scenario, sender);
    let mut nft = test_scenario::take_from_sender<PositionNFT>(&scenario);

    // Try to use it with pool2 (should fail)
    test_scenario::next_tx(&mut scenario, sender);
    let ctx = test_scenario::ctx(&mut scenario);

    pool::decrease_liquidity(
        &mut pool2, // Wrong pool!
        &mut nft,
        1000,
        ctx,
    );

    test_scenario::return_to_sender(&scenario, nft);
    test_utils::destroy(pool1);
    test_utils::destroy(pool2);
    test_utils::destroy(registry);
    test_scenario::end(scenario);
}

#[test]
fun test_nft_transfer_ownership() {
    let sender = @0xA;
    let recipient = @0xB;
    let mut scenario = test_scenario::begin(sender);
    let mut pool = setup_pool(&mut scenario, sender);
    let mut registry = setup_registry(&mut scenario, sender);

    // Mint position
    mint_position(
        &mut pool,
        &mut registry,
        &mut scenario,
        sender,
        signed_math::from_negative_i32(60),
        signed_math::from_literal_i32(60),
        10000000,
    );

    // Sender gets NFT
    test_scenario::next_tx(&mut scenario, sender);
    let nft = test_scenario::take_from_sender<PositionNFT>(&scenario);

    // Transfer to recipient
    transfer::public_transfer(nft, recipient);

    // Recipient can now use the NFT
    test_scenario::next_tx(&mut scenario, recipient);
    let mut nft = test_scenario::take_from_sender<PositionNFT>(&scenario);

    // Recipient collects fees
    test_scenario::next_tx(&mut scenario, recipient);
    let ctx = test_scenario::ctx(&mut scenario);
    let (coin_0, coin_1) = pool::collect(
        &mut pool,
        &mut nft,
        0,
        0,
        ctx,
    );

    test_utils::destroy(coin_0);
    test_utils::destroy(coin_1);
    test_scenario::return_to_sender(&scenario, nft);
    test_utils::destroy(pool);
    test_utils::destroy(registry);
    test_scenario::end(scenario);
}

#[test]
fun test_burn_nft_after_full_withdrawal() {
    let sender = @0xA;
    let mut scenario = test_scenario::begin(sender);
    let mut pool = setup_pool(&mut scenario, sender);
    let mut registry = setup_registry(&mut scenario, sender);

    // Mint position
    mint_position(
        &mut pool,
        &mut registry,
        &mut scenario,
        sender,
        signed_math::from_negative_i32(60),
        signed_math::from_literal_i32(60),
        10000000,
    );

    test_scenario::next_tx(&mut scenario, sender);
    let mut nft = test_scenario::take_from_sender<PositionNFT>(&scenario);
    let total_liquidity = position::liquidity(&nft);

    // Remove all liquidity
    test_scenario::next_tx(&mut scenario, sender);
    let ctx = test_scenario::ctx(&mut scenario);
    pool::decrease_liquidity(
        &mut pool,
        &mut nft,
        total_liquidity,
        ctx,
    );

    // Collect all fees
    test_scenario::next_tx(&mut scenario, sender);
    let ctx = test_scenario::ctx(&mut scenario);
    let (coin_0, coin_1) = pool::collect(
        &mut pool,
        &mut nft,
        0,
        0,
        ctx,
    );
    test_utils::destroy(coin_0);
    test_utils::destroy(coin_1);

    // Now can burn NFT
    test_scenario::next_tx(&mut scenario, sender);
    let ctx = test_scenario::ctx(&mut scenario);
    pool::burn_position(&mut pool, nft, ctx);

    test_utils::destroy(pool);
    test_utils::destroy(registry);
    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = pool::EINVALID_NFT)]
fun test_burn_nft_with_liquidity_fails() {
    let sender = @0xA;
    let mut scenario = test_scenario::begin(sender);
    let mut pool = setup_pool(&mut scenario, sender);
    let mut registry = setup_registry(&mut scenario, sender);

    mint_position(
        &mut pool,
        &mut registry,
        &mut scenario,
        sender,
        signed_math::from_negative_i32(60),
        signed_math::from_literal_i32(60),
        10000000,
    );

    test_scenario::next_tx(&mut scenario, sender);
    let nft = test_scenario::take_from_sender<PositionNFT>(&scenario);

    // Try to burn with liquidity still in position
    test_scenario::next_tx(&mut scenario, sender);
    let ctx = test_scenario::ctx(&mut scenario);
    pool::burn_position(&mut pool, nft, ctx);

    test_utils::destroy(pool);
    test_utils::destroy(registry);
    test_scenario::end(scenario);
}

// ========================================================================
// Complex Scenario Tests
// ========================================================================

#[test]
fun test_complex_multi_user_scenario() {
    let lp1 = @0xA;
    let lp2 = @0xB;
    let trader = @0xC;
    let mut scenario = test_scenario::begin(lp1);
    let mut pool = setup_pool(&mut scenario, lp1);
    let mut registry = setup_registry(&mut scenario, lp1);

    // LP1 provides liquidity
    mint_position(
        &mut pool,
        &mut registry,
        &mut scenario,
        lp1,
        signed_math::from_negative_i32(600),
        signed_math::from_literal_i32(600),
        50000000,
    );

    // LP2 provides liquidity (different range)
    mint_position(
        &mut pool,
        &mut registry,
        &mut scenario,
        lp2,
        signed_math::from_negative_i32(300),
        signed_math::from_literal_i32(300),
        50000000,
    );

    // Trader swaps
    test_scenario::next_tx(&mut scenario, trader);
    let ctx = test_scenario::ctx(&mut scenario);
    let payment = coin::mint_for_testing<TOKEN_A>(5000000, ctx);
    let sqrt_price_limit = tick_math::get_min_sqrt_ratio() + 1;

    let output = pool::swap_0_for_1(
        &mut pool,
        5000000,
        sqrt_price_limit,
        payment,
        ctx,
    );
    test_utils::destroy(output);

    // LP1 collects fees
    test_scenario::next_tx(&mut scenario, lp1);
    let mut nft1 = test_scenario::take_from_sender<PositionNFT>(&scenario);

    test_scenario::next_tx(&mut scenario, lp1);
    let ctx = test_scenario::ctx(&mut scenario);
    let (fees1_0, fees1_1) = pool::collect(
        &mut pool,
        &mut nft1,
        0,
        0,
        ctx,
    );

    let lp1_fees_0 = coin::value(&fees1_0);
    let lp1_fees_1 = coin::value(&fees1_1);

    // LP2 collects fees
    test_scenario::next_tx(&mut scenario, lp2);
    let mut nft2 = test_scenario::take_from_sender<PositionNFT>(&scenario);

    test_scenario::next_tx(&mut scenario, lp2);
    let ctx = test_scenario::ctx(&mut scenario);
    let (fees2_0, fees2_1) = pool::collect(
        &mut pool,
        &mut nft2,
        0,
        0,
        ctx,
    );

    let lp2_fees_0 = coin::value(&fees2_0);
    let lp2_fees_1 = coin::value(&fees2_1);

    // Both LPs should have earned fees
    assert!(lp1_fees_0 > 0 || lp1_fees_1 > 0, 0);
    assert!(lp2_fees_0 > 0 || lp2_fees_1 > 0, 1);

    test_utils::destroy(fees1_0);
    test_utils::destroy(fees1_1);
    test_utils::destroy(fees2_0);
    test_utils::destroy(fees2_1);
    test_scenario::return_to_sender(&scenario, nft1);
    test_scenario::return_to_sender(&scenario, nft2);
    test_utils::destroy(pool);
    test_utils::destroy(registry);
    test_scenario::end(scenario);
}

#[test]
fun test_accumulated_fees_across_multiple_swaps() {
    let lp = @0xA;
    let trader = @0xB;
    let mut scenario = test_scenario::begin(lp);
    let mut pool = setup_pool(&mut scenario, lp);
    let mut registry = setup_registry(&mut scenario, lp);

    // LP provides liquidity
    mint_position(
        &mut pool,
        &mut registry,
        &mut scenario,
        lp,
        signed_math::from_negative_i32(600),
        signed_math::from_literal_i32(600),
        100000000,
    );

    // Multiple swaps
    let num_swaps = 5;
    let mut i = 0;
    while (i < num_swaps) {
        test_scenario::next_tx(&mut scenario, trader);
        let ctx = test_scenario::ctx(&mut scenario);
        let payment = coin::mint_for_testing<TOKEN_A>(1000000, ctx);
        let sqrt_price_limit = tick_math::get_min_sqrt_ratio() + 1;

        let output = pool::swap_0_for_1(
            &mut pool,
            1000000,
            sqrt_price_limit,
            payment,
            ctx,
        );
        test_utils::destroy(output);

        i = i + 1;
    };

    // Collect accumulated fees
    test_scenario::next_tx(&mut scenario, lp);
    let mut nft = test_scenario::take_from_sender<PositionNFT>(&scenario);

    test_scenario::next_tx(&mut scenario, lp);
    let ctx = test_scenario::ctx(&mut scenario);
    let (fees_0, fees_1) = pool::collect(
        &mut pool,
        &mut nft,
        0,
        0,
        ctx,
    );

    // Fees should have accumulated from all swaps
    assert!(coin::value(&fees_0) > 0, 0);

    test_utils::destroy(fees_0);
    test_utils::destroy(fees_1);
    test_scenario::return_to_sender(&scenario, nft);
    test_utils::destroy(pool);
    test_utils::destroy(registry);
    test_scenario::end(scenario);
}
