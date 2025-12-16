module protocol::strategy;

use acl_dex_core::pool::{Self, Pool};
use protocol::agent::{Self, AgentCap};
use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::object::{Self, UID, ID};
use sui::transfer;
use sui::tx_context::{Self, TxContext};

// ==================== Errors ====================

const E_UNAUTHORIZED_AGENT: u64 = 1;

// ==================== Structs ====================

/// A Strategy Vault managed by an AI Agent
public struct StrategyVault<phantom X, phantom Y> has key {
    id: UID,
    /// The ID of the pool this strategy interacts with
    pool_id: ID,
    /// Current active tick range
    tick_lower: u32,
    tick_upper: u32,
    /// Idle funds
    balance_x: Balance<X>,
    balance_y: Balance<Y>,
    /// Tracked shares (simplified)
    total_shares: u64,
}

// ==================== Public Functions ====================

/// Create a new Strategy Vault
public fun create_vault<X, Y>(pool: &Pool<X, Y>, ctx: &mut TxContext) {
    let vault = StrategyVault<X, Y> {
        id: object::new(ctx),
        pool_id: object::id(pool),
        tick_lower: 0, // Uninitialized
        tick_upper: 0,
        balance_x: balance::zero(),
        balance_y: balance::zero(),
        total_shares: 0,
    };

    transfer::share_object(vault);
}

/// Rebalance the vault (Agent Only)
/// Withdraws liquidity from old range and deposits to new range
public fun rebalance<X, Y>(
    vault: &mut StrategyVault<X, Y>,
    agent_cap: &AgentCap,
    pool: &mut Pool<X, Y>,
    new_tick_lower: u32,
    new_tick_upper: u32,
    ctx: &mut TxContext,
) {
    // Check authorization
    // We need to convert vault.id to address to compare with managed_vault_id
    // object::uid_to_address(&vault.id) ? No, object::id_to_address(object::uid_to_inner(&vault.id))
    let vault_addr = object::uid_to_address(&vault.id);
    assert!(agent::managed_vault(agent_cap) == vault_addr, E_UNAUTHORIZED_AGENT);

    // 1. Remove Liquidity from old range (if any)
    // For MVP, we assume we just have idle balances to deposit.
    // In real impl, we'd call pool::remove_liquidity.

    // 2. Add Liquidity to new range
    // We take all idle balances and try to deposit.
    // Note: This requires `pool::add_liquidity` to be implemented/exposed.
    // Currently `pool.move` has `add_liquidity` but it might need updates for CLMM.
    // For now, we update the state to reflect the "Intent".

    vault.tick_lower = new_tick_lower;
    vault.tick_upper = new_tick_upper;

    // TODO: Execute actual liquidity move on the pool
}

/// Deposit into the vault
public fun deposit<X, Y>(
    vault: &mut StrategyVault<X, Y>,
    coin_x: Coin<X>,
    coin_y: Coin<Y>,
    ctx: &mut TxContext,
) {
    balance::join(&mut vault.balance_x, coin::into_balance(coin_x));
    balance::join(&mut vault.balance_y, coin::into_balance(coin_y));

    // Mint shares (simplified 1:1 for MVP)
    // In reality, calculate based on NAV.
}
