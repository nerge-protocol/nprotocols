/// Position NFT Module - ERC721-style NFT for liquidity positions
///
/// Each NFT represents a unique liquidity position in a pool.
/// Users can transfer, trade, or hold these NFTs like any other NFT.
///
/// Benefits:
/// - Positions are tradeable assets
/// - Clear ownership tracking
/// - Can be used as collateral in other DeFi protocols
/// - Compatible with NFT marketplaces
module acl_dex_core::position;

use std::string::{Self, String};
use sui::display;
use sui::event;
use sui::object::{Self, UID, ID};
use sui::package;
use sui::transfer;
use sui::tx_context::{Self, TxContext};

// ========================================================================
// Error Codes
// ========================================================================

const EUNAUTHORIZED: u64 = 1;
const EINVALID_POSITION: u64 = 2;

// ========================================================================
// Structs
// ========================================================================

/// One-time witness for creating Display
public struct POSITION has drop {}

/// Position NFT - represents ownership of a liquidity position
public struct PositionNFT has key, store {
    id: UID,
    /// Unique token ID
    token_id: u64,
    /// Pool this position belongs to
    pool_id: ID,
    /// Position tick range
    tick_lower: u32,
    tick_upper: u32,
    /// Position liquidity amount
    liquidity: u128,
    /// Fees accumulated
    tokens_owed_0: u64,
    tokens_owed_1: u64,
    /// Token symbols for display
    token0_symbol: String,
    token1_symbol: String,
}

/// Registry for managing token IDs
public struct PositionRegistry has key {
    id: UID,
    /// Counter for generating unique token IDs
    next_token_id: u64,
}

// ========================================================================
// Events
// ========================================================================

public struct PositionMinted has copy, drop {
    token_id: u64,
    pool_id: ID,
    owner: address,
    tick_lower: u32,
    tick_upper: u32,
    liquidity: u128,
}

public struct PositionBurned has copy, drop {
    token_id: u64,
    pool_id: ID,
    owner: address,
}

public struct LiquidityIncreased has copy, drop {
    token_id: u64,
    liquidity_delta: u128,
    amount0: u64,
    amount1: u64,
}

public struct LiquidityDecreased has copy, drop {
    token_id: u64,
    liquidity_delta: u128,
    amount0: u64,
    amount1: u64,
}

public struct FeesCollected has copy, drop {
    token_id: u64,
    amount0: u64,
    amount1: u64,
    recipient: address,
}

// ========================================================================
// Initialization
// ========================================================================

/// Initialize the module - create registry and display
fun init(otw: POSITION, ctx: &mut TxContext) {
    // Create registry
    let registry = PositionRegistry {
        id: object::new(ctx),
        next_token_id: 1,
    };
    transfer::share_object(registry);

    // Create publisher for Display
    let publisher = package::claim(otw, ctx);

    // Create Display for NFT metadata
    let mut display = display::new<PositionNFT>(&publisher, ctx);

    display::add(
        &mut display,
        string::utf8(b"name"),
        string::utf8(b"Nerge Position - {token0_symbol}/{token1_symbol}"),
    );
    display::add(
        &mut display,
        string::utf8(b"description"),
        string::utf8(
            b"This NFT represents a liquidity position in a Nerge pool. The owner can modify or redeem the position.",
        ),
    );
    display::add(
        &mut display,
        string::utf8(b"image_url"),
        string::utf8(b"https://example.com/position/{token_id}.svg"),
    );
    display::add(
        &mut display,
        string::utf8(b"project_url"),
        string::utf8(b"https://app.nerge.exchange"),
    );
    display::add(&mut display, string::utf8(b"creator"), string::utf8(b"Nerge"));

    display::update_version(&mut display);

    transfer::public_transfer(publisher, tx_context::sender(ctx));
    transfer::public_transfer(display, tx_context::sender(ctx));
}

// ========================================================================
// Core Functions
// ========================================================================

/// Mint a new position NFT
///
/// This is called when a user creates a new liquidity position
public fun mint(
    registry: &mut PositionRegistry,
    pool_id: ID,
    tick_lower: u32,
    tick_upper: u32,
    liquidity: u128,
    token0_symbol: String,
    token1_symbol: String,
    recipient: address,
    ctx: &mut TxContext,
): PositionNFT {
    let token_id = registry.next_token_id;
    registry.next_token_id = token_id + 1;

    let nft = PositionNFT {
        id: object::new(ctx),
        token_id,
        pool_id,
        tick_lower,
        tick_upper,
        liquidity,
        tokens_owed_0: 0,
        tokens_owed_1: 0,
        token0_symbol,
        token1_symbol,
    };

    event::emit(PositionMinted {
        token_id,
        pool_id,
        owner: recipient,
        tick_lower,
        tick_upper,
        liquidity,
    });

    nft
}

/// Burn a position NFT
///
/// Called when position is fully closed (liquidity = 0 and no fees owed)
public fun burn(nft: PositionNFT, ctx: &TxContext) {
    let PositionNFT {
        id,
        token_id,
        pool_id,
        tick_lower: _,
        tick_upper: _,
        liquidity,
        tokens_owed_0,
        tokens_owed_1,
        token0_symbol: _,
        token1_symbol: _,
    } = nft;

    // Ensure position is empty
    assert!(liquidity == 0, EINVALID_POSITION);
    assert!(tokens_owed_0 == 0, EINVALID_POSITION);
    assert!(tokens_owed_1 == 0, EINVALID_POSITION);

    event::emit(PositionBurned {
        token_id,
        pool_id,
        owner: tx_context::sender(ctx),
    });

    object::delete(id);
}

/// Increase liquidity in a position
public fun increase_liquidity(
    nft: &mut PositionNFT,
    liquidity_delta: u128,
    amount0: u64,
    amount1: u64,
) {
    nft.liquidity = nft.liquidity + liquidity_delta;

    event::emit(LiquidityIncreased {
        token_id: nft.token_id,
        liquidity_delta,
        amount0,
        amount1,
    });
}

/// Decrease liquidity in a position
public fun decrease_liquidity(
    nft: &mut PositionNFT,
    liquidity_delta: u128,
    amount0: u64,
    amount1: u64,
) {
    assert!(nft.liquidity >= liquidity_delta, EINVALID_POSITION);
    nft.liquidity = nft.liquidity - liquidity_delta;

    // Add amounts to tokens owed
    nft.tokens_owed_0 = nft.tokens_owed_0 + amount0;
    nft.tokens_owed_1 = nft.tokens_owed_1 + amount1;

    event::emit(LiquidityDecreased {
        token_id: nft.token_id,
        liquidity_delta,
        amount0,
        amount1,
    });
}

/// Collect fees from a position
public fun collect_fees(nft: &mut PositionNFT, amount0: u64, amount1: u64, recipient: address) {
    assert!(nft.tokens_owed_0 >= amount0, EINVALID_POSITION);
    assert!(nft.tokens_owed_1 >= amount1, EINVALID_POSITION);

    nft.tokens_owed_0 = nft.tokens_owed_0 - amount0;
    nft.tokens_owed_1 = nft.tokens_owed_1 - amount1;

    event::emit(FeesCollected {
        token_id: nft.token_id,
        amount0,
        amount1,
        recipient,
    });
}

/// Update tokens owed (when fees accrue)
public fun update_tokens_owed(nft: &mut PositionNFT, tokens_owed_0: u64, tokens_owed_1: u64) {
    nft.tokens_owed_0 = tokens_owed_0;
    nft.tokens_owed_1 = tokens_owed_1;
}

/// Add to tokens owed (for fee accumulation)
public fun add_tokens_owed(nft: &mut PositionNFT, amount0: u64, amount1: u64) {
    nft.tokens_owed_0 = nft.tokens_owed_0 + amount0;
    nft.tokens_owed_1 = nft.tokens_owed_1 + amount1;
}

// ========================================================================
// Getters
// ========================================================================

public fun token_id(nft: &PositionNFT): u64 {
    nft.token_id
}

public fun pool_id(nft: &PositionNFT): ID {
    nft.pool_id
}

public fun tick_lower(nft: &PositionNFT): u32 {
    nft.tick_lower
}

public fun tick_upper(nft: &PositionNFT): u32 {
    nft.tick_upper
}

public fun liquidity(nft: &PositionNFT): u128 {
    nft.liquidity
}

public fun tokens_owed_0(nft: &PositionNFT): u64 {
    nft.tokens_owed_0
}

public fun tokens_owed_1(nft: &PositionNFT): u64 {
    nft.tokens_owed_1
}

public fun token_symbols(nft: &PositionNFT): (String, String) {
    (nft.token0_symbol, nft.token1_symbol)
}

public fun position_info(nft: &PositionNFT): (u64, ID, u32, u32, u128, u64, u64) {
    (
        nft.token_id,
        nft.pool_id,
        nft.tick_lower,
        nft.tick_upper,
        nft.liquidity,
        nft.tokens_owed_0,
        nft.tokens_owed_1,
    )
}

// ========================================================================
// Validation
// ========================================================================

/// Check if NFT belongs to a specific pool
public fun is_from_pool(nft: &PositionNFT, pool_id: ID): bool {
    nft.pool_id == pool_id
}

/// Verify NFT ownership and pool
public fun verify_ownership(nft: &PositionNFT, expected_pool_id: ID, ctx: &TxContext) {
    assert!(is_from_pool(nft, expected_pool_id), EINVALID_POSITION);
}

// ========================================================================
// Tests
// ========================================================================

#[test_only]
use sui::test_scenario;

#[test]
fun test_mint_position_nft() {
    let mut scenario = test_scenario::begin(@0xA);

    // Create registry
    let mut registry = PositionRegistry {
        id: object::new(test_scenario::ctx(&mut scenario)),
        next_token_id: 1,
    };

    // Mint NFT
    let pool_id = object::id_from_address(@0xBEEF);
    let nft = mint(
        &mut registry,
        pool_id,
        100,
        200,
        1000000,
        string::utf8(b"SUI"),
        string::utf8(b"USDC"),
        @0xA,
        test_scenario::ctx(&mut scenario),
    );

    assert!(token_id(&nft) == 1, 0);
    assert!(registry.next_token_id == 2, 1);

    burn(nft, test_scenario::ctx(&mut scenario));

    // Clean up
    let PositionRegistry { id, next_token_id: _ } = registry;
    object::delete(id);
    test_scenario::end(scenario);
}

#[test]
fun test_increase_decrease_liquidity() {
    let mut scenario = test_scenario::begin(@0xA);

    let mut nft = PositionNFT {
        id: object::new(test_scenario::ctx(&mut scenario)),
        token_id: 1,
        pool_id: object::id_from_address(@0xBEEF),
        tick_lower: 100,
        tick_upper: 200,
        liquidity: 1000000,
        tokens_owed_0: 0,
        tokens_owed_1: 0,
        token0_symbol: string::utf8(b"SUI"),
        token1_symbol: string::utf8(b"USDC"),
    };

    // Increase liquidity
    increase_liquidity(&mut nft, 500000, 100, 100);
    assert!(nft.liquidity == 1500000, 0);

    // Decrease liquidity
    decrease_liquidity(&mut nft, 300000, 50, 50);
    assert!(nft.liquidity == 1200000, 1);
    assert!(nft.tokens_owed_0 == 50, 2);
    assert!(nft.tokens_owed_1 == 50, 3);

    // Collect fees
    collect_fees(&mut nft, 50, 50, @0xA);
    assert!(nft.tokens_owed_0 == 0, 4);
    assert!(nft.tokens_owed_1 == 0, 5);

    // Clean up
    let PositionNFT {
        id,
        token_id: _,
        pool_id: _,
        tick_lower: _,
        tick_upper: _,
        liquidity: _,
        tokens_owed_0: _,
        tokens_owed_1: _,
        token0_symbol: _,
        token1_symbol: _,
    } = nft;
    object::delete(id);

    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = EINVALID_POSITION)]
fun test_burn_with_liquidity_fails() {
    let mut scenario = test_scenario::begin(@0xA);

    let nft = PositionNFT {
        id: object::new(test_scenario::ctx(&mut scenario)),
        token_id: 1,
        pool_id: object::id_from_address(@0xBEEF),
        tick_lower: 100,
        tick_upper: 200,
        liquidity: 1000000, // Still has liquidity
        tokens_owed_0: 0,
        tokens_owed_1: 0,
        token0_symbol: string::utf8(b"SUI"),
        token1_symbol: string::utf8(b"USDC"),
    };

    // This should fail
    burn(nft, test_scenario::ctx(&mut scenario));

    test_scenario::end(scenario);
}

#[test_only]
public fun create_registry_for_testing(ctx: &mut TxContext): PositionRegistry {
    PositionRegistry {
        id: object::new(ctx),
        next_token_id: 1,
    }
}

#[test]
fun test_burn_empty_position() {
    let mut scenario = test_scenario::begin(@0xA);

    let nft = PositionNFT {
        id: object::new(test_scenario::ctx(&mut scenario)),
        token_id: 1,
        pool_id: object::id_from_address(@0xBEEF),
        tick_lower: 100,
        tick_upper: 200,
        liquidity: 0, // Empty
        tokens_owed_0: 0,
        tokens_owed_1: 0,
        token0_symbol: string::utf8(b"SUI"),
        token1_symbol: string::utf8(b"USDC"),
    };

    // This should succeed
    burn(nft, test_scenario::ctx(&mut scenario));

    test_scenario::end(scenario);
}
