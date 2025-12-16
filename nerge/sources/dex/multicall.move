/// Multicall - Batch multiple operations in one transaction
///
/// Provides:
/// - Collect fees from multiple positions
/// - Execute multiple swaps in sequence
/// - Coin management utilities
/// - Atomic execution (all succeed or all fail)
///
/// Benefits:
/// - Lower gas costs (one transaction instead of many)
/// - Atomic operations (no partial failures)
/// - Better UX (one signature for multiple actions)
///
/// Note: Due to Move's limitations, positions must be passed individually
/// rather than in vectors. Use the individual functions for each position.
module protocol::multicall;

use acl_dex_core::pool::{Self as pool, Pool};
use acl_dex_core::position::{Self, PositionNFT};
use sui::coin::{Self, Coin};
use sui::tx_context::{Self, TxContext};

// ========================================================================
// Error Codes
// ========================================================================

const EMISMATCH_ARRAY_LENGTHS: u64 = 1;
const EEMPTY_BATCH: u64 = 2;
const EZERO_AMOUNT: u64 = 3;

// ========================================================================
// Batch Collect Fees (2-5 positions)
// ========================================================================

/// Collect fees from 2 positions and merge results
public fun collect_from_two_positions<Token0, Token1>(
    pool: &mut Pool<Token0, Token1>,
    nft1: &mut PositionNFT,
    nft2: &mut PositionNFT,
    ctx: &mut TxContext,
): (Coin<Token0>, Coin<Token1>) {
    let (mut coin_0_1, mut coin_1_1) = pool::collect(pool, nft1, 0, 0, ctx);
    let (mut coin_0_2, mut coin_1_2) = pool::collect(pool, nft2, 0, 0, ctx);

    // Merge coins
    coin::join(&mut coin_0_1, coin_0_2);
    coin::join(&mut coin_1_1, coin_1_2);

    (coin_0_1, coin_1_1)
}

/// Collect fees from 3 positions and merge results
public fun collect_from_three_positions<Token0, Token1>(
    pool: &mut Pool<Token0, Token1>,
    nft1: &mut PositionNFT,
    nft2: &mut PositionNFT,
    nft3: &mut PositionNFT,
    ctx: &mut TxContext,
): (Coin<Token0>, Coin<Token1>) {
    let (mut coin_0, mut coin_1) = pool::collect(pool, nft1, 0, 0, ctx);

    let (coin_0_2, coin_1_2) = pool::collect(pool, nft2, 0, 0, ctx);
    coin::join(&mut coin_0, coin_0_2);
    coin::join(&mut coin_1, coin_1_2);

    let (coin_0_3, coin_1_3) = pool::collect(pool, nft3, 0, 0, ctx);
    coin::join(&mut coin_0, coin_0_3);
    coin::join(&mut coin_1, coin_1_3);

    (coin_0, coin_1)
}

/// Collect fees from 4 positions and merge results
public fun collect_from_four_positions<Token0, Token1>(
    pool: &mut Pool<Token0, Token1>,
    nft1: &mut PositionNFT,
    nft2: &mut PositionNFT,
    nft3: &mut PositionNFT,
    nft4: &mut PositionNFT,
    ctx: &mut TxContext,
): (Coin<Token0>, Coin<Token1>) {
    let (mut coin_0, mut coin_1) = collect_from_two_positions(pool, nft1, nft2, ctx);
    let (coin_0_34, coin_1_34) = collect_from_two_positions(pool, nft3, nft4, ctx);

    coin::join(&mut coin_0, coin_0_34);
    coin::join(&mut coin_1, coin_1_34);

    (coin_0, coin_1)
}

/// Collect fees from 5 positions and merge results
public fun collect_from_five_positions<Token0, Token1>(
    pool: &mut Pool<Token0, Token1>,
    nft1: &mut PositionNFT,
    nft2: &mut PositionNFT,
    nft3: &mut PositionNFT,
    nft4: &mut PositionNFT,
    nft5: &mut PositionNFT,
    ctx: &mut TxContext,
): (Coin<Token0>, Coin<Token1>) {
    let (mut coin_0, mut coin_1) = collect_from_four_positions(pool, nft1, nft2, nft3, nft4, ctx);
    let (coin_0_5, coin_1_5) = pool::collect(pool, nft5, 0, 0, ctx);

    coin::join(&mut coin_0, coin_0_5);
    coin::join(&mut coin_1, coin_1_5);

    (coin_0, coin_1)
}

// ========================================================================
// Entry Functions: Collect and Transfer
// ========================================================================

/// Entry function: Collect from 2 positions and transfer to sender
public entry fun collect_from_two_and_transfer<Token0, Token1>(
    pool: &mut Pool<Token0, Token1>,
    nft1: &mut PositionNFT,
    nft2: &mut PositionNFT,
    ctx: &mut TxContext,
) {
    let (coin_0, coin_1) = collect_from_two_positions(pool, nft1, nft2, ctx);
    transfer_or_destroy(coin_0, coin_1, ctx);
}

/// Entry function: Collect from 3 positions and transfer to sender
public entry fun collect_from_three_and_transfer<Token0, Token1>(
    pool: &mut Pool<Token0, Token1>,
    nft1: &mut PositionNFT,
    nft2: &mut PositionNFT,
    nft3: &mut PositionNFT,
    ctx: &mut TxContext,
) {
    let (coin_0, coin_1) = collect_from_three_positions(pool, nft1, nft2, nft3, ctx);
    transfer_or_destroy(coin_0, coin_1, ctx);
}

/// Entry function: Collect from 4 positions and transfer to sender
public entry fun collect_from_four_and_transfer<Token0, Token1>(
    pool: &mut Pool<Token0, Token1>,
    nft1: &mut PositionNFT,
    nft2: &mut PositionNFT,
    nft3: &mut PositionNFT,
    nft4: &mut PositionNFT,
    ctx: &mut TxContext,
) {
    let (coin_0, coin_1) = collect_from_four_positions(pool, nft1, nft2, nft3, nft4, ctx);
    transfer_or_destroy(coin_0, coin_1, ctx);
}

/// Entry function: Collect from 5 positions and transfer to sender
public entry fun collect_from_five_and_transfer<Token0, Token1>(
    pool: &mut Pool<Token0, Token1>,
    nft1: &mut PositionNFT,
    nft2: &mut PositionNFT,
    nft3: &mut PositionNFT,
    nft4: &mut PositionNFT,
    nft5: &mut PositionNFT,
    ctx: &mut TxContext,
) {
    let (coin_0, coin_1) = collect_from_five_positions(pool, nft1, nft2, nft3, nft4, nft5, ctx);
    transfer_or_destroy(coin_0, coin_1, ctx);
}

// ========================================================================
// Batch Decrease Liquidity (2-3 positions)
// ========================================================================

/// Decrease liquidity from 2 positions
public fun decrease_liquidity_from_two<Token0, Token1>(
    pool: &mut Pool<Token0, Token1>,
    nft1: &mut PositionNFT,
    nft2: &mut PositionNFT,
    liquidity1: u128,
    liquidity2: u128,
    ctx: &mut TxContext,
): (u64, u64, u64, u64) {
    let (amount_0_1, amount_1_1) = pool::decrease_liquidity(pool, nft1, liquidity1, ctx);
    let (amount_0_2, amount_1_2) = pool::decrease_liquidity(pool, nft2, liquidity2, ctx);

    (amount_0_1, amount_1_1, amount_0_2, amount_1_2)
}

/// Decrease liquidity from 3 positions
public fun decrease_liquidity_from_three<Token0, Token1>(
    pool: &mut Pool<Token0, Token1>,
    nft1: &mut PositionNFT,
    nft2: &mut PositionNFT,
    nft3: &mut PositionNFT,
    liquidity1: u128,
    liquidity2: u128,
    liquidity3: u128,
    ctx: &mut TxContext,
): (u64, u64, u64, u64, u64, u64) {
    let (amount_0_1, amount_1_1) = pool::decrease_liquidity(pool, nft1, liquidity1, ctx);
    let (amount_0_2, amount_1_2) = pool::decrease_liquidity(pool, nft2, liquidity2, ctx);
    let (amount_0_3, amount_1_3) = pool::decrease_liquidity(pool, nft3, liquidity3, ctx);

    (amount_0_1, amount_1_1, amount_0_2, amount_1_2, amount_0_3, amount_1_3)
}

// ========================================================================
// Sequential Swaps (Routing)
// ========================================================================

/// Execute 2 swaps in sequence (different pools)
/// Example: SUI -> USDC -> USDT
public fun swap_two_hops<Token0, Token1, Token2>(
    pool1: &mut Pool<Token0, Token1>,
    pool2: &mut Pool<Token1, Token2>,
    amount_in: u64,
    sqrt_price_limit_1: u256,
    sqrt_price_limit_2: u256,
    payment: Coin<Token0>,
    ctx: &mut TxContext,
): Coin<Token2> {
    assert!(amount_in > 0, EZERO_AMOUNT);

    // First hop: Token0 -> Token1
    let intermediate = pool::swap_0_for_1(
        pool1,
        amount_in,
        sqrt_price_limit_1,
        payment,
        ctx,
    );

    // Second hop: Token1 -> Token2
    let intermediate_amount = coin::value(&intermediate);
    pool::swap_0_for_1(
        pool2,
        intermediate_amount,
        sqrt_price_limit_2,
        intermediate,
        ctx,
    )
}

/// Execute 3 swaps in sequence
/// Example: SUI -> USDC -> USDT -> DAI
public fun swap_three_hops<Token0, Token1, Token2, Token3>(
    pool1: &mut Pool<Token0, Token1>,
    pool2: &mut Pool<Token1, Token2>,
    pool3: &mut Pool<Token2, Token3>,
    amount_in: u64,
    sqrt_price_limit_1: u256,
    sqrt_price_limit_2: u256,
    sqrt_price_limit_3: u256,
    payment: Coin<Token0>,
    ctx: &mut TxContext,
): Coin<Token3> {
    assert!(amount_in > 0, EZERO_AMOUNT);

    // First two hops
    let intermediate = swap_two_hops(
        pool1,
        pool2,
        amount_in,
        sqrt_price_limit_1,
        sqrt_price_limit_2,
        payment,
        ctx,
    );

    // Third hop: Token2 -> Token3
    let intermediate_amount = coin::value(&intermediate);
    pool::swap_0_for_1(
        pool3,
        intermediate_amount,
        sqrt_price_limit_3,
        intermediate,
        ctx,
    )
}

// ========================================================================
// Batch Same-Pool Swaps
// ========================================================================

/// Execute 2 swaps in the same pool
public fun batch_swap_two<Token0, Token1>(
    pool: &mut Pool<Token0, Token1>,
    amount_in_1: u64,
    amount_in_2: u64,
    sqrt_price_limit_1: u256,
    sqrt_price_limit_2: u256,
    payment_1: Coin<Token0>,
    payment_2: Coin<Token0>,
    ctx: &mut TxContext,
): (Coin<Token1>, Coin<Token1>) {
    assert!(amount_in_1 > 0 && amount_in_2 > 0, EZERO_AMOUNT);

    let output_1 = pool::swap_0_for_1(pool, amount_in_1, sqrt_price_limit_1, payment_1, ctx);
    let output_2 = pool::swap_0_for_1(pool, amount_in_2, sqrt_price_limit_2, payment_2, ctx);

    (output_1, output_2)
}

/// Execute 3 swaps in the same pool
public fun batch_swap_three<Token0, Token1>(
    pool: &mut Pool<Token0, Token1>,
    amount_in_1: u64,
    amount_in_2: u64,
    amount_in_3: u64,
    sqrt_price_limit_1: u256,
    sqrt_price_limit_2: u256,
    sqrt_price_limit_3: u256,
    payment_1: Coin<Token0>,
    payment_2: Coin<Token0>,
    payment_3: Coin<Token0>,
    ctx: &mut TxContext,
): (Coin<Token1>, Coin<Token1>, Coin<Token1>) {
    assert!(amount_in_1 > 0 && amount_in_2 > 0 && amount_in_3 > 0, EZERO_AMOUNT);

    let output_1 = pool::swap_0_for_1(pool, amount_in_1, sqrt_price_limit_1, payment_1, ctx);
    let output_2 = pool::swap_0_for_1(pool, amount_in_2, sqrt_price_limit_2, payment_2, ctx);
    let output_3 = pool::swap_0_for_1(pool, amount_in_3, sqrt_price_limit_3, payment_3, ctx);

    (output_1, output_2, output_3)
}

// ========================================================================
// Cross-Pool Operations
// ========================================================================

/// Collect fees from positions in two different pools
public fun collect_cross_pools<Token0_A, Token1_A, Token0_B, Token1_B>(
    pool_a: &mut Pool<Token0_A, Token1_A>,
    pool_b: &mut Pool<Token0_B, Token1_B>,
    nft_a1: &mut PositionNFT,
    nft_a2: &mut PositionNFT,
    nft_b1: &mut PositionNFT,
    nft_b2: &mut PositionNFT,
    ctx: &mut TxContext,
): (Coin<Token0_A>, Coin<Token1_A>, Coin<Token0_B>, Coin<Token1_B>) {
    let (coin_0_a, coin_1_a) = collect_from_two_positions(pool_a, nft_a1, nft_a2, ctx);
    let (coin_0_b, coin_1_b) = collect_from_two_positions(pool_b, nft_b1, nft_b2, ctx);

    (coin_0_a, coin_1_a, coin_0_b, coin_1_b)
}

// ========================================================================
// Utility Functions
// ========================================================================

/// Merge 2 coins
public fun merge_two_coins<T>(mut coin1: Coin<T>, coin2: Coin<T>): Coin<T> {
    coin::join(&mut coin1, coin2);
    coin1
}

/// Merge 3 coins
public fun merge_three_coins<T>(coin1: Coin<T>, coin2: Coin<T>, coin3: Coin<T>): Coin<T> {
    let mut merged = coin1;
    coin::join(&mut merged, coin2);
    coin::join(&mut merged, coin3);
    merged
}

/// Merge 4 coins
public fun merge_four_coins<T>(
    coin1: Coin<T>,
    coin2: Coin<T>,
    coin3: Coin<T>,
    coin4: Coin<T>,
): Coin<T> {
    let mut merged = coin1;
    coin::join(&mut merged, coin2);
    coin::join(&mut merged, coin3);
    coin::join(&mut merged, coin4);
    merged
}

/// Split a coin into 2 parts
public fun split_into_two<T>(coin: &mut Coin<T>, amount: u64, ctx: &mut TxContext): Coin<T> {
    coin::split(coin, amount, ctx)
}

/// Split a coin into 3 parts
public fun split_into_three<T>(
    coin: &mut Coin<T>,
    amount1: u64,
    amount2: u64,
    ctx: &mut TxContext,
): (Coin<T>, Coin<T>) {
    let split1 = coin::split(coin, amount1, ctx);
    let split2 = coin::split(coin, amount2, ctx);
    (split1, split2)
}

/// Split a coin into 4 parts
public fun split_into_four<T>(
    coin: &mut Coin<T>,
    amount1: u64,
    amount2: u64,
    amount3: u64,
    ctx: &mut TxContext,
): (Coin<T>, Coin<T>, Coin<T>) {
    let split1 = coin::split(coin, amount1, ctx);
    let split2 = coin::split(coin, amount2, ctx);
    let split3 = coin::split(coin, amount3, ctx);
    (split1, split2, split3)
}

// ========================================================================
// Helper Functions
// ========================================================================

/// Transfer coins to sender or destroy if zero
fun transfer_or_destroy<Token0, Token1>(
    coin_0: Coin<Token0>,
    coin_1: Coin<Token1>,
    ctx: &TxContext,
) {
    let sender = tx_context::sender(ctx);

    if (coin::value(&coin_0) > 0) {
        sui::transfer::public_transfer(coin_0, sender);
    } else {
        coin::destroy_zero(coin_0);
    };

    if (coin::value(&coin_1) > 0) {
        sui::transfer::public_transfer(coin_1, sender);
    } else {
        coin::destroy_zero(coin_1);
    };
}

// ========================================================================
// Tests
// ========================================================================

#[test_only]
use sui::test_scenario;
#[test_only]
use sui::test_utils;

#[test_only]
public struct TOKEN_X has drop {}
#[test_only]
public struct TOKEN_Y has drop {}

#[test]
fun test_merge_two_coins() {
    let user = @0xA;
    let mut scenario = test_scenario::begin(user);
    let ctx = test_scenario::ctx(&mut scenario);

    let coin1 = coin::mint_for_testing<TOKEN_X>(100, ctx);
    let coin2 = coin::mint_for_testing<TOKEN_X>(200, ctx);

    let merged = merge_two_coins(coin1, coin2);
    assert!(coin::value(&merged) == 300, 0);

    test_utils::destroy(merged);
    test_scenario::end(scenario);
}

#[test]
fun test_split_into_two() {
    let user = @0xA;
    let mut scenario = test_scenario::begin(user);
    let ctx = test_scenario::ctx(&mut scenario);

    let mut coin = coin::mint_for_testing<TOKEN_X>(1000, ctx);

    let split = split_into_two(&mut coin, 300, ctx);

    assert!(coin::value(&split) == 300, 0);
    assert!(coin::value(&coin) == 700, 1);

    test_utils::destroy(split);
    test_utils::destroy(coin);
    test_scenario::end(scenario);
}

#[test]
fun test_merge_three_coins() {
    let user = @0xA;
    let mut scenario = test_scenario::begin(user);
    let ctx = test_scenario::ctx(&mut scenario);

    let coin1 = coin::mint_for_testing<TOKEN_X>(100, ctx);
    let coin2 = coin::mint_for_testing<TOKEN_X>(200, ctx);
    let coin3 = coin::mint_for_testing<TOKEN_X>(300, ctx);

    let merged = merge_three_coins(coin1, coin2, coin3);
    assert!(coin::value(&merged) == 600, 0);

    test_utils::destroy(merged);
    test_scenario::end(scenario);
}
