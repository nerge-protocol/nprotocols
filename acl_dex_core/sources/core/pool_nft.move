/// Pool Module - NFT-First Integration
///
/// This version uses Position NFTs as the primary way to represent liquidity positions.
/// Users receive NFTs when providing liquidity, making positions tradeable assets.
module acl_dex_core::pool;

use acl_dex_core::position::{Self, PositionNFT, PositionRegistry};
use acl_dex_core::tick::{Self, TickManager};
use nerge_math_lib::full_math;
use nerge_math_lib::liquidity_math;
use nerge_math_lib::signed_math;
use nerge_math_lib::swap_math;
use nerge_math_lib::tick_math;
use std::string::{Self, String};
use std::type_name;
use std::vector;
use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::event;
use sui::object::{Self, UID, ID};
use sui::table::{Self, Table};
use sui::transfer;
use sui::tx_context::{Self, TxContext};

// ========================================================================
// Constants
// ========================================================================

const MAX_FEE: u32 = 1000000;
const FEE_LOW: u32 = 500;
const FEE_MEDIUM: u32 = 3000;
const FEE_HIGH: u32 = 10000;
const FEE_DENOMINATOR: u32 = 1000000;

// ========================================================================
// Error Codes
// ========================================================================

const EINVALID_FEE: u64 = 1;
const EINVALID_TICK_SPACING: u64 = 2;
const EINVALID_SQRT_PRICE: u64 = 3;
const EINVALID_TICK_RANGE: u64 = 6;
const ETICK_OUT_OF_BOUNDS: u64 = 7;
const EZERO_LIQUIDITY: u64 = 8;
const EINSUFFICIENT_AMOUNT_0: u64 = 9;
const EINSUFFICIENT_AMOUNT_1: u64 = 10;
const EZERO_AMOUNT: u64 = 11;
const EINSUFFICIENT_LIQUIDITY: u64 = 13;
const ETICK_NOT_ALIGNED: u64 = 14;
const EINVALID_NFT: u64 = 15;
const ENFT_WRONG_POOL: u64 = 16;
const E_SLIPPAGE_LIMIT: u64 = 17;

// ========================================================================
// Structs
// ========================================================================

/// Main pool state container
public struct Pool<phantom Token0, phantom Token1> has key, store {
    id: UID,
    // Config
    fee: u32,
    tick_spacing: u32,
    // Current state
    sqrt_price_x96: u256,
    tick: u32,
    liquidity: u128,
    // Fee tracking
    fee_growth_global_0_x128: u256,
    fee_growth_global_1_x128: u256,
    // Protocol fees
    protocol_fees_token0: u64,
    protocol_fees_token1: u64,
    // Token reserves
    balance_0: Balance<Token0>,
    balance_1: Balance<Token1>,
    // Tick management
    tick_manager: TickManager,
    // Position tracking by NFT token_id
    position_data: Table<u64, PositionData>,
    // Token symbols for NFT display
    token0_symbol: String,
    token1_symbol: String,
}

/// Internal position data stored in pool
/// The NFT holds ownership, this holds the position state
public struct PositionData has copy, drop, store {
    tick_lower: u32,
    tick_upper: u32,
    liquidity: u128,
    fee_growth_inside_0_last_x128: u256,
    fee_growth_inside_1_last_x128: u256,
    tokens_owed_0: u64,
    tokens_owed_1: u64,
}

/// Swap state during execution
public struct SwapState has copy, drop {
    amount_specified_remaining: u256,
    amount_calculated: u256,
    sqrt_price_x96: u256,
    tick: u32,
    liquidity: u128,
}

/// Result of one swap step
public struct StepResult has copy, drop {
    sqrt_price_next_x96: u256,
    tick_next: u32,
    initialized: bool,
}

// ========================================================================
// Events
// ========================================================================

public struct PoolCreated<phantom X, phantom Y> has copy, drop {
    pool_id: ID,
    token0_symbol: String,
    token1_symbol: String,
}

public struct LiquidityAdded<phantom X, phantom Y> has copy, drop {
    pool_id: ID,
    token_id: u64,
    provider: address,
    amount_x: u64,
    amount_y: u64,
    liquidity_minted: u128,
}

public struct LiquidityRemoved<phantom X, phantom Y> has copy, drop {
    pool_id: ID,
    token_id: u64,
    provider: address,
    amount_x: u64,
    amount_y: u64,
    liquidity_burned: u128,
}

public struct Swap<phantom X, phantom Y> has copy, drop {
    pool_id: ID,
    trader: address,
    amount_in: u64,
    amount_out: u64,
    is_x_to_y: bool,
}

// ========================================================================
// Pool Creation
// ========================================================================

public fun create_pool<Token0, Token1>(
    fee: u32,
    tick_spacing: u32,
    sqrt_price_x96: u256,
    ctx: &mut TxContext,
): Pool<Token0, Token1> {
    // Validation
    assert!(fee > 0 && fee <= MAX_FEE, EINVALID_FEE);
    assert!(tick_spacing > 0, EINVALID_TICK_SPACING);

    let min_sqrt_ratio = tick_math::get_min_sqrt_ratio();
    let max_sqrt_ratio = tick_math::get_max_sqrt_ratio();

    assert!(
        sqrt_price_x96 >= min_sqrt_ratio && sqrt_price_x96 < max_sqrt_ratio,
        EINVALID_SQRT_PRICE,
    );

    // Calculate starting tick
    let tick = tick_math::get_tick_at_sqrt_ratio(sqrt_price_x96);
    let tick_aligned = tick_math::round_down_to_spacing(tick, tick_spacing);

    // Extract token symbols from type names
    let token0_name = type_name::get<Token0>();
    let token1_name = type_name::get<Token1>();

    let token0_ascii = type_name::into_string(token0_name);
    let token1_ascii = type_name::into_string(token1_name);

    let token0_str = string::from_ascii(token0_ascii);
    let token1_str = string::from_ascii(token1_ascii);

    let token0_symbol = extract_symbol(&token0_str);
    let token1_symbol = extract_symbol(&token1_str);

    let pool = Pool {
        id: object::new(ctx),
        fee,
        tick_spacing,
        sqrt_price_x96,
        tick: tick_aligned,
        liquidity: 0,
        fee_growth_global_0_x128: 0,
        fee_growth_global_1_x128: 0,
        protocol_fees_token0: 0,
        protocol_fees_token1: 0,
        balance_0: balance::zero(),
        balance_1: balance::zero(),
        tick_manager: tick::new(ctx),
        position_data: table::new(ctx),
        token0_symbol,
        token1_symbol,
    };

    event::emit(PoolCreated<Token0, Token1> {
        pool_id: object::id(&pool),
        token0_symbol: pool.token0_symbol,
        token1_symbol: pool.token1_symbol,
    });

    pool
}

public entry fun create_and_share_pool<Token0, Token1>(
    fee: u32,
    tick_spacing: u32,
    sqrt_price_x96: u256,
    ctx: &mut TxContext,
) {
    let pool = create_pool<Token0, Token1>(fee, tick_spacing, sqrt_price_x96, ctx);
    transfer::share_object(pool);
}

// ========================================================================
// Mint - Add Liquidity (Returns NFT)
// ========================================================================

/// Add liquidity and receive Position NFT
///
/// This is the primary way to provide liquidity. Users receive an NFT
/// representing their position, which they can hold, transfer, or trade.
///
/// Returns: (amount0, amount1, liquidity, token_id)
public fun mint<Token0, Token1>(
    pool: &mut Pool<Token0, Token1>,
    registry: &mut PositionRegistry,
    tick_lower: u32,
    tick_upper: u32,
    amount_desired_0: u64,
    amount_desired_1: u64,
    amount_min_0: u64,
    amount_min_1: u64,
    payment_0: Coin<Token0>,
    payment_1: Coin<Token1>,
    recipient: address,
    ctx: &mut TxContext,
): (u64, u64, u128, u64) {
    // Validate ticks
    assert!(
        signed_math::greater_than_or_equal_i32(tick_lower, tick_math::get_min_tick()),
        ETICK_OUT_OF_BOUNDS,
    );
    assert!(
        signed_math::less_than_or_equal_i32(tick_upper, tick_math::get_max_tick()),
        ETICK_OUT_OF_BOUNDS,
    );
    assert!(signed_math::less_than_i32(tick_lower, tick_upper), EINVALID_TICK_RANGE);
    assert!(signed_math::abs_i32(tick_lower) % pool.tick_spacing == 0, ETICK_NOT_ALIGNED);
    assert!(signed_math::abs_i32(tick_upper) % pool.tick_spacing == 0, ETICK_NOT_ALIGNED);

    // Calculate liquidity
    let sqrt_ratio_lower_x96 = tick_math::get_sqrt_ratio_at_tick(tick_lower);
    let sqrt_ratio_upper_x96 = tick_math::get_sqrt_ratio_at_tick(tick_upper);

    let liquidity = liquidity_math::get_liquidity_for_amounts(
        pool.sqrt_price_x96,
        sqrt_ratio_lower_x96,
        sqrt_ratio_upper_x96,
        (amount_desired_0 as u256),
        (amount_desired_1 as u256),
    );

    assert!(liquidity > 0, EZERO_LIQUIDITY);

    let amounts = liquidity_math::get_amounts_for_liquidity(
        pool.sqrt_price_x96,
        sqrt_ratio_lower_x96,
        sqrt_ratio_upper_x96,
        liquidity,
    );

    let amount0 = (liquidity_math::get_amount0(&amounts) as u64);
    let amount1 = (liquidity_math::get_amount1(&amounts) as u64);

    assert!(amount0 >= amount_min_0, EINSUFFICIENT_AMOUNT_0);
    assert!(amount1 >= amount_min_1, EINSUFFICIENT_AMOUNT_1);

    // Get fee growth inside
    let (fee_growth_inside_0, fee_growth_inside_1) = tick::get_fee_growth_inside(
        &pool.tick_manager,
        tick_lower,
        tick_upper,
        pool.tick,
        pool.fee_growth_global_0_x128,
        pool.fee_growth_global_1_x128,
    );

    // Mint Position NFT
    let token_id = position::mint(
        registry,
        object::id(pool),
        tick_lower,
        tick_upper,
        liquidity,
        pool.token0_symbol,
        pool.token1_symbol,
        recipient,
        ctx,
    );

    // Store position data in pool
    table::add(
        &mut pool.position_data,
        token_id,
        PositionData {
            tick_lower,
            tick_upper,
            liquidity,
            fee_growth_inside_0_last_x128: fee_growth_inside_0,
            fee_growth_inside_1_last_x128: fee_growth_inside_1,
            tokens_owed_0: 0,
            tokens_owed_1: 0,
        },
    );

    // Update ticks
    tick::update_for_mint(
        &mut pool.tick_manager,
        tick_lower,
        liquidity,
        false,
        pool.tick,
        pool.fee_growth_global_0_x128,
        pool.fee_growth_global_1_x128,
        pool.tick_spacing,
    );

    tick::update_for_mint(
        &mut pool.tick_manager,
        tick_upper,
        liquidity,
        true,
        pool.tick,
        pool.fee_growth_global_0_x128,
        pool.fee_growth_global_1_x128,
        pool.tick_spacing,
    );

    // Update global liquidity if price in range
    if (
        signed_math::greater_than_or_equal_i32(pool.tick, tick_lower) &&
        signed_math::less_than_i32(pool.tick, tick_upper)
    ) {
        pool.liquidity = pool.liquidity + liquidity;
    };

    // Transfer tokens
    let mut coin_0_balance = coin::into_balance(payment_0);
    let mut coin_1_balance = coin::into_balance(payment_1);

    let amount_0_balance = balance::split(&mut coin_0_balance, amount0);
    let amount_1_balance = balance::split(&mut coin_1_balance, amount1);

    balance::join(&mut pool.balance_0, amount_0_balance);
    balance::join(&mut pool.balance_1, amount_1_balance);

    // Return change
    if (balance::value(&coin_0_balance) > 0) {
        transfer::public_transfer(coin::from_balance(coin_0_balance, ctx), recipient);
    } else {
        balance::destroy_zero(coin_0_balance);
    };

    if (balance::value(&coin_1_balance) > 0) {
        transfer::public_transfer(coin::from_balance(coin_1_balance, ctx), recipient);
    } else {
        balance::destroy_zero(coin_1_balance);
    };

    event::emit(LiquidityAdded<Token0, Token1> {
        pool_id: object::id(pool),
        token_id,
        provider: recipient,
        amount_x: amount0,
        amount_y: amount1,
        liquidity_minted: liquidity,
    });

    (amount0, amount1, liquidity, token_id)
}

// ========================================================================
// Increase Liquidity (Requires NFT)
// ========================================================================

/// Add more liquidity to an existing position
///
/// Requires ownership of the Position NFT
public fun increase_liquidity<Token0, Token1>(
    pool: &mut Pool<Token0, Token1>,
    nft: &mut PositionNFT,
    amount_desired_0: u64,
    amount_desired_1: u64,
    amount_min_0: u64,
    amount_min_1: u64,
    payment_0: Coin<Token0>,
    payment_1: Coin<Token1>,
    ctx: &mut TxContext,
): (u64, u64, u128) {
    // Verify NFT is for this pool
    assert!(position::is_from_pool(nft, object::id(pool)), ENFT_WRONG_POOL);

    let token_id = position::token_id(nft);
    let tick_lower = position::tick_lower(nft);
    let tick_upper = position::tick_upper(nft);

    // Calculate liquidity to add
    let sqrt_ratio_lower_x96 = tick_math::get_sqrt_ratio_at_tick(tick_lower);
    let sqrt_ratio_upper_x96 = tick_math::get_sqrt_ratio_at_tick(tick_upper);

    let liquidity_delta = liquidity_math::get_liquidity_for_amounts(
        pool.sqrt_price_x96,
        sqrt_ratio_lower_x96,
        sqrt_ratio_upper_x96,
        (amount_desired_0 as u256),
        (amount_desired_1 as u256),
    );

    assert!(liquidity_delta > 0, EZERO_LIQUIDITY);

    let amounts = liquidity_math::get_amounts_for_liquidity(
        pool.sqrt_price_x96,
        sqrt_ratio_lower_x96,
        sqrt_ratio_upper_x96,
        liquidity_delta,
    );

    let amount0 = (liquidity_math::get_amount0(&amounts) as u64);
    let amount1 = (liquidity_math::get_amount1(&amounts) as u64);

    assert!(amount0 >= amount_min_0, EINSUFFICIENT_AMOUNT_0);
    assert!(amount1 >= amount_min_1, EINSUFFICIENT_AMOUNT_1);

    // Update position data
    let position = table::borrow_mut(&mut pool.position_data, token_id);

    // Calculate and add accumulated fees
    let (fee_growth_inside_0, fee_growth_inside_1) = tick::get_fee_growth_inside(
        &pool.tick_manager,
        tick_lower,
        tick_upper,
        pool.tick,
        pool.fee_growth_global_0_x128,
        pool.fee_growth_global_1_x128,
    );

    if (position.liquidity > 0) {
        let fees_0 = calculate_fees_owed(
            position.liquidity,
            fee_growth_inside_0,
            position.fee_growth_inside_0_last_x128,
        );
        let fees_1 = calculate_fees_owed(
            position.liquidity,
            fee_growth_inside_1,
            position.fee_growth_inside_1_last_x128,
        );

        position.tokens_owed_0 = position.tokens_owed_0 + fees_0;
        position.tokens_owed_1 = position.tokens_owed_1 + fees_1;
    };

    position.fee_growth_inside_0_last_x128 = fee_growth_inside_0;
    position.fee_growth_inside_1_last_x128 = fee_growth_inside_1;
    position.liquidity = position.liquidity + liquidity_delta;

    // Update NFT
    position::increase_liquidity(nft, liquidity_delta, amount0, amount1);

    // Update ticks
    tick::update_for_mint(
        &mut pool.tick_manager,
        tick_lower,
        liquidity_delta,
        false,
        pool.tick,
        pool.fee_growth_global_0_x128,
        pool.fee_growth_global_1_x128,
        pool.tick_spacing,
    );

    tick::update_for_mint(
        &mut pool.tick_manager,
        tick_upper,
        liquidity_delta,
        true,
        pool.tick,
        pool.fee_growth_global_0_x128,
        pool.fee_growth_global_1_x128,
        pool.tick_spacing,
    );

    // Update global liquidity if in range
    if (
        signed_math::greater_than_or_equal_i32(pool.tick, tick_lower) &&
        signed_math::less_than_i32(pool.tick, tick_upper)
    ) {
        pool.liquidity = pool.liquidity + liquidity_delta;
    };

    // Transfer tokens
    let mut coin_0_balance = coin::into_balance(payment_0);
    let mut coin_1_balance = coin::into_balance(payment_1);

    let amount_0_balance = balance::split(&mut coin_0_balance, amount0);
    let amount_1_balance = balance::split(&mut coin_1_balance, amount1);

    balance::join(&mut pool.balance_0, amount_0_balance);
    balance::join(&mut pool.balance_1, amount_1_balance);

    // Return change
    let recipient = tx_context::sender(ctx);
    if (balance::value(&coin_0_balance) > 0) {
        transfer::public_transfer(coin::from_balance(coin_0_balance, ctx), recipient);
    } else {
        balance::destroy_zero(coin_0_balance);
    };

    if (balance::value(&coin_1_balance) > 0) {
        transfer::public_transfer(coin::from_balance(coin_1_balance, ctx), recipient);
    } else {
        balance::destroy_zero(coin_1_balance);
    };

    (amount0, amount1, liquidity_delta)
}

// ========================================================================
// Decrease Liquidity (Requires NFT)
// ========================================================================

/// Remove liquidity from a position
///
/// Requires ownership of the Position NFT
/// Tokens are added to tokens_owed and can be collected
public fun decrease_liquidity<Token0, Token1>(
    pool: &mut Pool<Token0, Token1>,
    nft: &mut PositionNFT,
    liquidity: u128,
    ctx: &mut TxContext,
): (u64, u64) {
    assert!(liquidity > 0, EZERO_LIQUIDITY);
    assert!(position::is_from_pool(nft, object::id(pool)), ENFT_WRONG_POOL);

    let token_id = position::token_id(nft);
    let tick_lower = position::tick_lower(nft);
    let tick_upper = position::tick_upper(nft);

    let position = table::borrow_mut(&mut pool.position_data, token_id);
    assert!(position.liquidity >= liquidity, EZERO_LIQUIDITY);

    // Calculate amounts
    let sqrt_ratio_lower_x96 = tick_math::get_sqrt_ratio_at_tick(tick_lower);
    let sqrt_ratio_upper_x96 = tick_math::get_sqrt_ratio_at_tick(tick_upper);

    let amounts = liquidity_math::get_amounts_for_liquidity(
        pool.sqrt_price_x96,
        sqrt_ratio_lower_x96,
        sqrt_ratio_upper_x96,
        liquidity,
    );

    let amount0 = (liquidity_math::get_amount0(&amounts) as u64);
    let amount1 = (liquidity_math::get_amount1(&amounts) as u64);

    // Update fees
    let (fee_growth_inside_0, fee_growth_inside_1) = tick::get_fee_growth_inside(
        &pool.tick_manager,
        tick_lower,
        tick_upper,
        pool.tick,
        pool.fee_growth_global_0_x128,
        pool.fee_growth_global_1_x128,
    );

    position.tokens_owed_0 =
        position.tokens_owed_0 + calculate_fees_owed(
        position.liquidity,
        fee_growth_inside_0,
        position.fee_growth_inside_0_last_x128,
    );
    position.tokens_owed_1 =
        position.tokens_owed_1 + calculate_fees_owed(
        position.liquidity,
        fee_growth_inside_1,
        position.fee_growth_inside_1_last_x128,
    );

    position.fee_growth_inside_0_last_x128 = fee_growth_inside_0;
    position.fee_growth_inside_1_last_x128 = fee_growth_inside_1;
    position.liquidity = position.liquidity - liquidity;
    position.tokens_owed_0 = position.tokens_owed_0 + amount0;
    position.tokens_owed_1 = position.tokens_owed_1 + amount1;

    // Update NFT
    position::decrease_liquidity(nft, liquidity, amount0, amount1);

    // Update ticks
    tick::update_for_burn(&mut pool.tick_manager, tick_lower, liquidity, false, pool.tick_spacing);
    tick::update_for_burn(&mut pool.tick_manager, tick_upper, liquidity, true, pool.tick_spacing);

    // Update global liquidity
    if (
        signed_math::greater_than_or_equal_i32(pool.tick, tick_lower) &&
        signed_math::less_than_i32(pool.tick, tick_upper)
    ) {
        pool.liquidity = pool.liquidity - liquidity;
    };

    event::emit(LiquidityRemoved<Token0, Token1> {
        pool_id: object::id(pool),
        token_id,
        provider: tx_context::sender(ctx),
        amount_x: amount0,
        amount_y: amount1,
        liquidity_burned: liquidity,
    });

    (amount0, amount1)
}

// ========================================================================
// Collect Fees (Requires NFT)
// ========================================================================

/// Collect fees from a position
///
/// Requires ownership of the Position NFT
public fun collect<Token0, Token1>(
    pool: &mut Pool<Token0, Token1>,
    nft: &mut PositionNFT,
    amount0_requested: u64,
    amount1_requested: u64,
    ctx: &mut TxContext,
): (Coin<Token0>, Coin<Token1>) {
    assert!(position::is_from_pool(nft, object::id(pool)), ENFT_WRONG_POOL);

    let token_id = position::token_id(nft);
    let tick_lower = position::tick_lower(nft);
    let tick_upper = position::tick_upper(nft);

    let position = table::borrow_mut(&mut pool.position_data, token_id);

    // Update fees first
    if (position.liquidity > 0) {
        let (fee_growth_inside_0, fee_growth_inside_1) = tick::get_fee_growth_inside(
            &pool.tick_manager,
            tick_lower,
            tick_upper,
            pool.tick,
            pool.fee_growth_global_0_x128,
            pool.fee_growth_global_1_x128,
        );

        let fees_0 = calculate_fees_owed(
            position.liquidity,
            fee_growth_inside_0,
            position.fee_growth_inside_0_last_x128,
        );
        let fees_1 = calculate_fees_owed(
            position.liquidity,
            fee_growth_inside_1,
            position.fee_growth_inside_1_last_x128,
        );

        position.tokens_owed_0 = position.tokens_owed_0 + fees_0;
        position.tokens_owed_1 = position.tokens_owed_1 + fees_1;

        position.fee_growth_inside_0_last_x128 = fee_growth_inside_0;
        position.fee_growth_inside_1_last_x128 = fee_growth_inside_1;
    };

    // Determine collect amounts
    let amount0 = if (amount0_requested == 0) {
        position.tokens_owed_0
    } else {
        if (amount0_requested > position.tokens_owed_0) {
            position.tokens_owed_0
        } else {
            amount0_requested
        }
    };

    let amount1 = if (amount1_requested == 0) {
        position.tokens_owed_1
    } else {
        if (amount1_requested > position.tokens_owed_1) {
            position.tokens_owed_1
        } else {
            amount1_requested
        }
    };

    position.tokens_owed_0 = position.tokens_owed_0 - amount0;
    position.tokens_owed_1 = position.tokens_owed_1 - amount1;

    // Update NFT
    let recipient = tx_context::sender(ctx);

    // Sync NFT with pool position data
    position::update_tokens_owed(nft, position.tokens_owed_0, position.tokens_owed_1);
    // position::collect_fees(nft, amount0, amount1, recipient);

    // Transfer tokens
    let balance_0 = balance::split(&mut pool.balance_0, amount0);
    let balance_1 = balance::split(&mut pool.balance_1, amount1);

    (coin::from_balance(balance_0, ctx), coin::from_balance(balance_1, ctx))
}

/// Convenience function to collect all fees
public entry fun collect_all<Token0, Token1>(
    pool: &mut Pool<Token0, Token1>,
    nft: &mut PositionNFT,
    ctx: &mut TxContext,
) {
    let (coin_0, coin_1) = collect(pool, nft, 0, 0, ctx);

    let recipient = tx_context::sender(ctx);

    if (coin::value(&coin_0) > 0) {
        transfer::public_transfer(coin_0, recipient);
    } else {
        coin::destroy_zero(coin_0);
    };

    if (coin::value(&coin_1) > 0) {
        transfer::public_transfer(coin_1, recipient);
    } else {
        coin::destroy_zero(coin_1);
    };
}

// ========================================================================
// Burn NFT (Close Position)
// ========================================================================

/// Burn the Position NFT and clean up position data
///
/// Position must have no liquidity and no fees owed
public entry fun burn_position<Token0, Token1>(
    pool: &mut Pool<Token0, Token1>,
    nft: PositionNFT,
    ctx: &TxContext,
) {
    assert!(position::is_from_pool(&nft, object::id(pool)), ENFT_WRONG_POOL);

    let token_id = position::token_id(&nft);

    // Remove position data from pool
    let position = table::remove(&mut pool.position_data, token_id);
    assert!(position.liquidity == 0, EINVALID_NFT);
    assert!(position.tokens_owed_0 == 0, EINVALID_NFT);
    assert!(position.tokens_owed_1 == 0, EINVALID_NFT);

    // Burn the NFT
    position::burn(nft, ctx);
}

// ========================================================================
// Swap Functions
// ========================================================================

/// Swap X for Y
public fun swap_exact_input<X, Y>(
    pool: &mut Pool<X, Y>,
    coin_in: Coin<X>,
    min_out: u64,
    ctx: &mut TxContext,
): Coin<Y> {
    let amount_in_total = coin::value(&coin_in);

    // Price limit for 0 -> 1 is min_sqrt_ratio + 1
    let price_limit = tick_math::get_min_sqrt_ratio() + 1;

    let (amount_in_computed, amount_out_computed) = execute_swap_internal(
        pool,
        true, // zero_for_one
        amount_in_total,
        price_limit,
    );

    let amount_in = (amount_in_computed as u64);
    let amount_out = (amount_out_computed as u64);

    assert!(amount_out >= min_out, E_SLIPPAGE_LIMIT);

    // Handle Input Payment
    let mut balance_in = coin::into_balance(coin_in);
    let balance_used = balance::split(&mut balance_in, amount_in);
    balance::join(&mut pool.balance_0, balance_used);

    // Refund excess input
    if (balance::value(&balance_in) > 0) {
        transfer::public_transfer(
            coin::from_balance(balance_in, ctx),
            tx_context::sender(ctx),
        );
    } else {
        balance::destroy_zero(balance_in);
    };

    // Handle Output
    let balance_out = balance::split(&mut pool.balance_1, amount_out);
    let coin_out = coin::from_balance(balance_out, ctx);

    // Emit Event
    event::emit(Swap<X, Y> {
        pool_id: object::id(pool),
        trader: tx_context::sender(ctx),
        amount_in,
        amount_out,
        is_x_to_y: true,
    });

    coin_out
}

/// Swap Y for X (Token1 -> Token0) with exact input
public fun swap_exact_input_1_for_0<X, Y>(
    pool: &mut Pool<X, Y>,
    coin_in: Coin<Y>,
    min_out: u64,
    ctx: &mut TxContext,
): Coin<X> {
    let amount_in_total = coin::value(&coin_in);

    // Price limit for 1 -> 0 is max_sqrt_ratio - 1
    let price_limit = tick_math::get_max_sqrt_ratio() - 1;

    let (amount_in_computed, amount_out_computed) = execute_swap_internal(
        pool,
        false, // zero_for_one = false (Y -> X)
        amount_in_total,
        price_limit,
    );

    let amount_in = (amount_in_computed as u64);
    let amount_out = (amount_out_computed as u64);

    assert!(amount_out >= min_out, E_SLIPPAGE_LIMIT);

    // Handle Input Payment
    let mut balance_in = coin::into_balance(coin_in);
    let balance_used = balance::split(&mut balance_in, amount_in);
    balance::join(&mut pool.balance_1, balance_used);

    // Refund excess input
    if (balance::value(&balance_in) > 0) {
        transfer::public_transfer(
            coin::from_balance(balance_in, ctx),
            tx_context::sender(ctx),
        );
    } else {
        balance::destroy_zero(balance_in);
    };

    // Handle Output
    let balance_out = balance::split(&mut pool.balance_0, amount_out);
    let coin_out = coin::from_balance(balance_out, ctx);

    // Emit Event
    event::emit(Swap<X, Y> {
        pool_id: object::id(pool),
        trader: tx_context::sender(ctx),
        amount_in,
        amount_out,
        is_x_to_y: false,
    });

    coin_out
}

public fun swap_0_for_1<Token0, Token1>(
    pool: &mut Pool<Token0, Token1>,
    amount_specified: u64,
    sqrt_price_limit_x96: u256,
    payment: Coin<Token0>,
    ctx: &mut TxContext,
): Coin<Token1> {
    let (amount_in, amount_out) = execute_swap_internal(
        pool,
        true,
        amount_specified,
        sqrt_price_limit_x96,
    );

    let mut payment_balance = coin::into_balance(payment);
    let amount_in_balance = balance::split(&mut payment_balance, (amount_in as u64));
    balance::join(&mut pool.balance_0, amount_in_balance);

    if (balance::value(&payment_balance) > 0) {
        transfer::public_transfer(
            coin::from_balance(payment_balance, ctx),
            tx_context::sender(ctx),
        );
    } else {
        balance::destroy_zero(payment_balance);
    };

    let amount_out_balance = balance::split(&mut pool.balance_1, (amount_out as u64));
    coin::from_balance(amount_out_balance, ctx)
}

public fun swap_1_for_0<Token0, Token1>(
    pool: &mut Pool<Token0, Token1>,
    amount_specified: u64,
    sqrt_price_limit_x96: u256,
    payment: Coin<Token1>,
    ctx: &mut TxContext,
): Coin<Token0> {
    let (amount_in, amount_out) = execute_swap_internal(
        pool,
        false,
        amount_specified,
        sqrt_price_limit_x96,
    );

    let mut payment_balance = coin::into_balance(payment);
    let amount_in_balance = balance::split(&mut payment_balance, (amount_in as u64));
    balance::join(&mut pool.balance_1, amount_in_balance);

    if (balance::value(&payment_balance) > 0) {
        transfer::public_transfer(
            coin::from_balance(payment_balance, ctx),
            tx_context::sender(ctx),
        );
    } else {
        balance::destroy_zero(payment_balance);
    };

    let amount_out_balance = balance::split(&mut pool.balance_0, (amount_out as u64));
    coin::from_balance(amount_out_balance, ctx)
}

fun execute_swap_internal<Token0, Token1>(
    pool: &mut Pool<Token0, Token1>,
    zero_for_one: bool,
    amount_specified: u64,
    sqrt_price_limit_x96: u256,
): (u256, u256) {
    assert!(amount_specified > 0, EZERO_AMOUNT);
    assert!(pool.liquidity > 0, EINSUFFICIENT_LIQUIDITY);

    if (zero_for_one) {
        assert!(
            sqrt_price_limit_x96 < pool.sqrt_price_x96 &&
            sqrt_price_limit_x96 >= tick_math::get_min_sqrt_ratio(),
            EINVALID_SQRT_PRICE,
        );
    } else {
        assert!(
            sqrt_price_limit_x96 > pool.sqrt_price_x96 &&
            sqrt_price_limit_x96 <= tick_math::get_max_sqrt_ratio(),
            EINVALID_SQRT_PRICE,
        );
    };

    let mut state = SwapState {
        amount_specified_remaining: (amount_specified as u256),
        amount_calculated: 0,
        sqrt_price_x96: pool.sqrt_price_x96,
        tick: pool.tick,
        liquidity: pool.liquidity,
    };

    while (
        state.amount_specified_remaining > 0 &&
        state.sqrt_price_x96 != sqrt_price_limit_x96
    ) {
        let step = next_initialized_tick_within_one_word(
            pool,
            state.tick,
            pool.tick_spacing,
            zero_for_one,
        );

        let sqrt_price_target_x96 = if (
            (zero_for_one && step.sqrt_price_next_x96 < sqrt_price_limit_x96) ||
            (!zero_for_one && step.sqrt_price_next_x96 > sqrt_price_limit_x96)
        ) {
            sqrt_price_limit_x96
        } else {
            step.sqrt_price_next_x96
        };

        let swap_step_result = swap_math::compute_swap_step(
            state.sqrt_price_x96,
            sqrt_price_target_x96,
            state.liquidity,
            state.amount_specified_remaining,
            pool.fee,
        );

        state.sqrt_price_x96 = swap_math::get_sqrt_price_next(&swap_step_result);

        let amount_in = swap_math::get_amount_in(&swap_step_result);
        let amount_out = swap_math::get_amount_out(&swap_step_result);
        let fee_amount = swap_math::get_fee_amount(&swap_step_result);

        state.amount_specified_remaining =
            state.amount_specified_remaining - amount_in - fee_amount;
        state.amount_calculated = state.amount_calculated + amount_out;

        if (state.liquidity > 0) {
            let fee_growth_delta = (fee_amount << 128) / (state.liquidity as u256);
            if (zero_for_one) {
                pool.fee_growth_global_0_x128 = pool.fee_growth_global_0_x128 + fee_growth_delta;
            } else {
                pool.fee_growth_global_1_x128 = pool.fee_growth_global_1_x128 + fee_growth_delta;
            };
        };

        if (state.sqrt_price_x96 == step.sqrt_price_next_x96) {
            if (step.initialized) {
                let (liquidity_net, is_negative) = tick::cross(
                    &mut pool.tick_manager,
                    step.tick_next,
                    pool.fee_growth_global_0_x128,
                    pool.fee_growth_global_1_x128,
                );

                if (zero_for_one) {
                    if (is_negative) {
                        state.liquidity = state.liquidity + liquidity_net;
                    } else {
                        if (state.liquidity >= liquidity_net) {
                            state.liquidity = state.liquidity - liquidity_net;
                        } else {
                            state.liquidity = 0;
                        };
                    };
                } else {
                    if (is_negative) {
                        if (state.liquidity >= liquidity_net) {
                            state.liquidity = state.liquidity - liquidity_net;
                        } else {
                            state.liquidity = 0;
                        };
                    } else {
                        state.liquidity = state.liquidity + liquidity_net;
                    };
                };
            };
            state.tick = if (zero_for_one) {
                signed_math::sub_i32(step.tick_next, 1)
            } else {
                step.tick_next
            };
        } else {
            state.tick = tick_math::get_tick_at_sqrt_ratio(state.sqrt_price_x96);
        };
    };

    pool.sqrt_price_x96 = state.sqrt_price_x96;
    pool.tick = state.tick;
    pool.liquidity = state.liquidity;

    let amount_in_total = (amount_specified as u256) - state.amount_specified_remaining;
    let amount_out_total = state.amount_calculated;

    (amount_in_total, amount_out_total)
}

// ========================================================================
// Tick Navigation
// ========================================================================

fun next_initialized_tick_within_one_word<Token0, Token1>(
    pool: &Pool<Token0, Token1>,
    tick: u32,
    tick_spacing: u32,
    lte: bool,
): StepResult {
    let (next_tick, initialized) = tick::next_initialized_tick_within_one_word(
        &pool.tick_manager,
        tick,
        tick_spacing,
        lte,
    );

    let sqrt_price_next = tick_math::get_sqrt_ratio_at_tick(next_tick);

    StepResult {
        sqrt_price_next_x96: sqrt_price_next,
        tick_next: next_tick,
        initialized,
    }
}

// ========================================================================
// View Functions
// ========================================================================

public fun get_slot0<Token0, Token1>(pool: &Pool<Token0, Token1>): (u256, u32, u128) {
    (pool.sqrt_price_x96, pool.tick, pool.liquidity)
}

public fun get_config<Token0, Token1>(pool: &Pool<Token0, Token1>): (u32, u32) {
    (pool.fee, pool.tick_spacing)
}

public fun get_balances<Token0, Token1>(pool: &Pool<Token0, Token1>): (u64, u64) {
    (balance::value(&pool.balance_0), balance::value(&pool.balance_1))
}

public fun get_fee_growth_global<Token0, Token1>(pool: &Pool<Token0, Token1>): (u256, u256) {
    (pool.fee_growth_global_0_x128, pool.fee_growth_global_1_x128)
}

public fun get_token_symbols<Token0, Token1>(pool: &Pool<Token0, Token1>): (String, String) {
    (pool.token0_symbol, pool.token1_symbol)
}

/// Get position data from pool by NFT token_id
public fun get_position_data<Token0, Token1>(
    pool: &Pool<Token0, Token1>,
    token_id: u64,
): (u32, u32, u128, u256, u256, u64, u64) {
    if (!table::contains(&pool.position_data, token_id)) {
        return (0, 0, 0, 0, 0, 0, 0)
    };

    let pos = table::borrow(&pool.position_data, token_id);
    (
        pos.tick_lower,
        pos.tick_upper,
        pos.liquidity,
        pos.fee_growth_inside_0_last_x128,
        pos.fee_growth_inside_1_last_x128,
        pos.tokens_owed_0,
        pos.tokens_owed_1,
    )
}

/// Get current pool reserves
public fun get_reserves<X, Y>(pool: &Pool<X, Y>): (u64, u64) {
    (balance::value(&pool.balance_0), balance::value(&pool.balance_1))
}

/// Calculate output amount for given input
public fun get_amount_out<X, Y>(pool: &Pool<X, Y>, amount_in: u64, is_x_to_y: bool): u64 {
    let (reserve_in, reserve_out) = if (is_x_to_y) {
        (balance::value(&pool.balance_0), balance::value(&pool.balance_1))
    } else {
        (balance::value(&pool.balance_1), balance::value(&pool.balance_0))
    };

    let amount_in_with_fee = amount_in * (10000 - pool.fee as u64) / 10000;
    (amount_in_with_fee * reserve_out) / (reserve_in + amount_in_with_fee)
}

// /// Get Sqrt price of the pool
// public fun get_sqrt_price<X, Y>(pool: &Pool<X, Y>): u256 {
//     pool.sqrt_price_x96
// }

// ========================================================================
// Helper Functions
// ========================================================================

fun calculate_fees_owed(
    liquidity: u128,
    fee_growth_inside: u256,
    fee_growth_inside_last: u256,
): u64 {
    let fee_growth_delta = fee_growth_inside - fee_growth_inside_last;

    let fees = full_math::mul_div(
        (liquidity as u256),
        fee_growth_delta,
        (1u256 << 128),
    );

    (fees as u64)
}

/// Extract symbol from type name
/// E.g., "0x2::sui::SUI" -> "SUI"
fun extract_symbol(type_str: &String): String {
    let bytes = string::as_bytes(type_str);
    let mut i = vector::length(bytes);

    // Iterate from end to find last "::"
    while (i > 0) {
        i = i - 1;
        if (i > 0 && *vector::borrow(bytes, i) == 58u8 && *vector::borrow(bytes, i - 1) == 58u8) {
            // Found "::" at i-1 and i
            return string::substring(type_str, i + 1, vector::length(bytes))
        };
    };

    // If no "::" found (shouldn't happen for fully qualified types), return whole string
    *type_str
}

// ========================================================================
// Tests
// ========================================================================

#[test_only]
use sui::test_scenario;
#[test_only]
use sui::test_utils;
#[test_only]
public struct SUI has drop {}
#[test_only]
public struct USDC has drop {}

#[test]
fun test_create_pool_with_nft() {
    let mut scenario = test_scenario::begin(@0xA);
    let ctx = test_scenario::ctx(&mut scenario);

    let sqrt_price_x96 = 79228162514264337593543950336_u256;
    let pool = create_pool<SUI, USDC>(FEE_MEDIUM, 60, sqrt_price_x96, ctx);

    let (price, tick, liquidity) = get_slot0(&pool);
    assert!(price == sqrt_price_x96, 0);
    assert!(liquidity == 0, 1);

    test_utils::destroy(pool);
    test_scenario::end(scenario);
}

#[test]
fun test_mint_position_nft() {
    let mut scenario = test_scenario::begin(@0xA);
    let ctx = test_scenario::ctx(&mut scenario);

    // Create pool
    let sqrt_price = 79228162514264337593543950336_u256;
    let mut pool = create_pool<SUI, USDC>(FEE_MEDIUM, 60, sqrt_price, ctx);

    // Create registry
    let mut registry = position::create_registry_for_testing(ctx);

    // Mint position with NFT
    let tick_lower = signed_math::from_negative_i32(60);
    let tick_upper = signed_math::from_literal_i32(60);

    let payment_0 = coin::mint_for_testing<SUI>(1000000, ctx);
    let payment_1 = coin::mint_for_testing<USDC>(1000000, ctx);

    let (amount0, amount1, liquidity, token_id) = mint(
        &mut pool,
        &mut registry,
        tick_lower,
        tick_upper,
        1000000,
        1000000,
        0,
        0,
        payment_0,
        payment_1,
        @0xA,
        ctx,
    );

    assert!(liquidity > 0, 0);
    assert!(amount0 > 0, 1);
    assert!(amount1 > 0, 2);
    assert!(token_id == 1, 3);

    // Verify position data in pool
    let (t_lower, t_upper, liq, _, _, _, _) = get_position_data(&pool, token_id);
    assert!(t_lower == tick_lower, 4);
    assert!(t_upper == tick_upper, 5);
    assert!(liq == liquidity, 6);

    test_utils::destroy(pool);
    test_utils::destroy(registry);
    test_scenario::end(scenario);
}
