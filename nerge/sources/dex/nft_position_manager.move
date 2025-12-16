/// NFT Position Manager - User-friendly position management
///
/// Provides high-level functions for:
/// - Minting positions with slippage protection
/// - Adding/removing liquidity
/// - Collecting fees
/// - Position information queries
///
/// This is the main interface users interact with for liquidity provision
module protocol::nft_position_manager;

use acl_dex_core::pool::{Self as pool, Pool};
use acl_dex_core::position::{Self, PositionNFT, PositionRegistry};
use nerge_math_lib::signed_math;
use nerge_math_lib::tick_math;
use std::string::String;
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::tx_context::{Self, TxContext};

// ========================================================================
// Error Codes
// ========================================================================

const EDEADLINE_EXCEEDED: u64 = 1;
const EINSUFFICIENT_AMOUNT_0: u64 = 2;
const EINSUFFICIENT_AMOUNT_1: u64 = 3;
const EINVALID_TICK_RANGE: u64 = 4;
const EZERO_LIQUIDITY: u64 = 5;

// ========================================================================
// Structs
// ========================================================================

/// Parameters for minting a new position
public struct MintParams has drop {
    tick_lower: u32,
    tick_upper: u32,
    amount_0_desired: u64,
    amount_1_desired: u64,
    amount_0_min: u64,
    amount_1_min: u64,
    recipient: address,
    deadline: u64,
}

/// Parameters for increasing liquidity
public struct IncreaseLiquidityParams has drop {
    amount_0_desired: u64,
    amount_1_desired: u64,
    amount_0_min: u64,
    amount_1_min: u64,
    deadline: u64,
}

/// Parameters for decreasing liquidity
public struct DecreaseLiquidityParams has drop {
    liquidity: u128,
    amount_0_min: u64,
    amount_1_min: u64,
    deadline: u64,
}

/// Parameters for collecting fees
public struct CollectParams has drop {
    amount_0_max: u64,
    amount_1_max: u64,
}

// ========================================================================
// Mint New Position
// ========================================================================

/// Mint a new liquidity position and receive an NFT
///
/// This is the primary way users provide liquidity.
/// Returns NFT representing ownership of the position.
///
/// Example:
/// ```
/// let params = create_mint_params(
///     -600,  // tick_lower
///     600,   // tick_upper
///     1000000,  // amount_0_desired
///     1000000,  // amount_1_desired
///     950000,   // amount_0_min (5% slippage)
///     950000,   // amount_1_min
///     @user,
///     deadline
/// );
///
/// let (token_id, liquidity, amount_0, amount_1) = mint(
///     &mut pool,
///     &mut registry,
///     params,
///     payment_0,
///     payment_1,
///     &clock,
///     ctx
/// );
/// ```
public fun mint<Token0, Token1>(
    pool: &mut Pool<Token0, Token1>,
    registry: &mut PositionRegistry,
    params: MintParams,
    payment_0: Coin<Token0>,
    payment_1: Coin<Token1>,
    clock: &Clock,
    ctx: &mut TxContext,
): (u64, u128, u64, u64) {
    // Check deadline
    check_deadline(clock, params.deadline);

    // Validate parameters
    assert!(signed_math::less_than_i32(params.tick_lower, params.tick_upper), EINVALID_TICK_RANGE);

    // Mint position
    let (amount_0, amount_1, liquidity, token_id) = pool::mint(
        pool,
        registry,
        params.tick_lower,
        params.tick_upper,
        params.amount_0_desired,
        params.amount_1_desired,
        params.amount_0_min,
        params.amount_1_min,
        payment_0,
        payment_1,
        params.recipient,
        ctx,
    );

    assert!(liquidity > 0, EZERO_LIQUIDITY);

    (token_id, liquidity, amount_0, amount_1)
}

// ========================================================================
// Increase Liquidity
// ========================================================================

/// Add more liquidity to an existing position
///
/// User must own the NFT for this position.
public fun increase_liquidity<Token0, Token1>(
    pool: &mut Pool<Token0, Token1>,
    nft: &mut PositionNFT,
    params: IncreaseLiquidityParams,
    payment_0: Coin<Token0>,
    payment_1: Coin<Token1>,
    clock: &Clock,
    ctx: &mut TxContext,
): (u128, u64, u64) {
    check_deadline(clock, params.deadline);

    let (amount_0, amount_1, liquidity) = pool::increase_liquidity(
        pool,
        nft,
        params.amount_0_desired,
        params.amount_1_desired,
        params.amount_0_min,
        params.amount_1_min,
        payment_0,
        payment_1,
        ctx,
    );

    assert!(amount_0 >= params.amount_0_min, EINSUFFICIENT_AMOUNT_0);
    assert!(amount_1 >= params.amount_1_min, EINSUFFICIENT_AMOUNT_1);

    (liquidity, amount_0, amount_1)
}

// ========================================================================
// Decrease Liquidity
// ========================================================================

/// Remove liquidity from a position
///
/// Tokens are not transferred yet - they're stored in tokens_owed
/// and can be collected later with collect()
public fun decrease_liquidity<Token0, Token1>(
    pool: &mut Pool<Token0, Token1>,
    nft: &mut PositionNFT,
    params: DecreaseLiquidityParams,
    clock: &Clock,
    ctx: &mut TxContext,
): (u64, u64) {
    check_deadline(clock, params.deadline);

    let (amount_0, amount_1) = pool::decrease_liquidity(
        pool,
        nft,
        params.liquidity,
        ctx,
    );

    assert!(amount_0 >= params.amount_0_min, EINSUFFICIENT_AMOUNT_0);
    assert!(amount_1 >= params.amount_1_min, EINSUFFICIENT_AMOUNT_1);

    (amount_0, amount_1)
}

// ========================================================================
// Collect Fees
// ========================================================================

/// Collect fees and tokens from decreased liquidity
///
/// Returns coins that can be transferred or used elsewhere
public fun collect<Token0, Token1>(
    pool: &mut Pool<Token0, Token1>,
    nft: &mut PositionNFT,
    params: CollectParams,
    ctx: &mut TxContext,
): (Coin<Token0>, Coin<Token1>) {
    pool::collect(
        pool,
        nft,
        params.amount_0_max,
        params.amount_1_max,
        ctx,
    )
}

/// Collect all available fees and tokens
public fun collect_all<Token0, Token1>(
    pool: &mut Pool<Token0, Token1>,
    nft: &mut PositionNFT,
    ctx: &mut TxContext,
): (Coin<Token0>, Coin<Token1>) {
    pool::collect(pool, nft, 0, 0, ctx)
}

// ========================================================================
// Burn Position
// ========================================================================

/// Close a position and burn the NFT
///
/// Position must have zero liquidity and no fees owed
public entry fun burn<Token0, Token1>(
    pool: &mut Pool<Token0, Token1>,
    nft: PositionNFT,
    ctx: &TxContext,
) {
    pool::burn_position(pool, nft, ctx);
}

// ========================================================================
// Parameter Builders
// ========================================================================

/// Create mint parameters with automatic recipient
public fun create_mint_params(
    tick_lower: u32,
    tick_upper: u32,
    amount_0_desired: u64,
    amount_1_desired: u64,
    amount_0_min: u64,
    amount_1_min: u64,
    recipient: address,
    deadline: u64,
): MintParams {
    MintParams {
        tick_lower,
        tick_upper,
        amount_0_desired,
        amount_1_desired,
        amount_0_min,
        amount_1_min,
        recipient,
        deadline,
    }
}

/// Create mint parameters with 5% slippage tolerance
public fun create_mint_params_with_slippage(
    tick_lower: u32,
    tick_upper: u32,
    amount_0_desired: u64,
    amount_1_desired: u64,
    recipient: address,
    deadline: u64,
): MintParams {
    let amount_0_min = (amount_0_desired as u128) * 95 / 100;
    let amount_1_min = (amount_1_desired as u128) * 95 / 100;

    create_mint_params(
        tick_lower,
        tick_upper,
        amount_0_desired,
        amount_1_desired,
        (amount_0_min as u64),
        (amount_1_min as u64),
        recipient,
        deadline,
    )
}

/// Create increase liquidity parameters
public fun create_increase_liquidity_params(
    amount_0_desired: u64,
    amount_1_desired: u64,
    amount_0_min: u64,
    amount_1_min: u64,
    deadline: u64,
): IncreaseLiquidityParams {
    IncreaseLiquidityParams {
        amount_0_desired,
        amount_1_desired,
        amount_0_min,
        amount_1_min,
        deadline,
    }
}

/// Create decrease liquidity parameters
public fun create_decrease_liquidity_params(
    liquidity: u128,
    amount_0_min: u64,
    amount_1_min: u64,
    deadline: u64,
): DecreaseLiquidityParams {
    DecreaseLiquidityParams {
        liquidity,
        amount_0_min,
        amount_1_min,
        deadline,
    }
}

/// Create collect parameters
public fun create_collect_params(amount_0_max: u64, amount_1_max: u64): CollectParams {
    CollectParams {
        amount_0_max,
        amount_1_max,
    }
}

/// Create collect all parameters
public fun create_collect_all_params(): CollectParams {
    CollectParams {
        amount_0_max: 0, // 0 means collect all
        amount_1_max: 0,
    }
}

// ========================================================================
// Helper Functions
// ========================================================================

fun check_deadline(clock: &Clock, deadline: u64) {
    let current_time = clock::timestamp_ms(clock) / 1000;
    assert!(current_time <= deadline, EDEADLINE_EXCEEDED);
}

/// Calculate deadline from current time
public fun calculate_deadline(clock: &Clock, duration_seconds: u64): u64 {
    let current_time = clock::timestamp_ms(clock) / 1000;
    current_time + duration_seconds
}

// ========================================================================
// Position Information Queries
// ========================================================================

/// Get position information from NFT
public fun get_position_info(nft: &PositionNFT): (u64, u32, u32, u128, u64, u64) {
    let token_id = position::token_id(nft);
    let tick_lower = position::tick_lower(nft);
    let tick_upper = position::tick_upper(nft);
    let liquidity = position::liquidity(nft);
    let tokens_owed_0 = position::tokens_owed_0(nft);
    let tokens_owed_1 = position::tokens_owed_1(nft);

    (token_id, tick_lower, tick_upper, liquidity, tokens_owed_0, tokens_owed_1)
}

/// Check if position is in range (has active liquidity)
public fun is_position_in_range<Token0, Token1>(
    pool: &Pool<Token0, Token1>,
    nft: &PositionNFT,
): bool {
    let (_, current_tick, _) = pool::get_slot0(pool);
    let tick_lower = position::tick_lower(nft);
    let tick_upper = position::tick_upper(nft);

    signed_math::greater_than_or_equal_i32(current_tick, tick_lower) &&
    signed_math::less_than_i32(current_tick, tick_upper)
}

// ========================================================================
// Entry Functions (Convenient wrappers)
// ========================================================================

/// Entry function: Mint position and transfer NFT to sender
public entry fun mint_position<Token0, Token1>(
    pool: &mut Pool<Token0, Token1>,
    registry: &mut PositionRegistry,
    tick_lower: u32,
    tick_upper: u32,
    amount_0_desired: u64,
    amount_1_desired: u64,
    payment_0: Coin<Token0>,
    payment_1: Coin<Token1>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let sender = tx_context::sender(ctx);
    let deadline = calculate_deadline(clock, 600); // 10 minutes

    let params = create_mint_params_with_slippage(
        tick_lower,
        tick_upper,
        amount_0_desired,
        amount_1_desired,
        sender,
        deadline,
    );

    mint(pool, registry, params, payment_0, payment_1, clock, ctx);
    // NFT is automatically transferred to sender by pool::mint
}

/// Entry function: Collect all fees and transfer to sender
public entry fun collect_all_fees<Token0, Token1>(
    pool: &mut Pool<Token0, Token1>,
    nft: &mut PositionNFT,
    ctx: &mut TxContext,
) {
    let (coin_0, coin_1) = collect_all(pool, nft, ctx);

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
