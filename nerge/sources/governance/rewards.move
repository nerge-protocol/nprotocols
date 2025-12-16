module protocol::rewards;

use protocol::agent::{Self, AgentCap};
use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::object::{Self, UID};
use sui::transfer;
use sui::tx_context::{Self, TxContext};

// ==================== Structs ====================

/// Reward Pool holding governance tokens
public struct RewardPool<phantom T> has key {
    id: UID,
    balance: Balance<T>,
}

// ==================== Public Functions ====================

/// Create a new Reward Pool
public fun create_pool<T>(ctx: &mut TxContext) {
    let pool = RewardPool<T> {
        id: object::new(ctx),
        balance: balance::zero(),
    };
    transfer::share_object(pool);
}

/// Fund the reward pool
public fun fund<T>(pool: &mut RewardPool<T>, coin: Coin<T>) {
    balance::join(&mut pool.balance, coin::into_balance(coin));
}

/// Distribute rewards to an agent (Admin/Governance only)
public fun distribute<T>(
    pool: &mut RewardPool<T>,
    agent_cap: &mut AgentCap,
    amount: u64,
    ctx: &mut TxContext,
) {
    // In reality, check performance score and calculate amount dynamically.
    // For MVP, simplistic distribution.

    let coin = coin::take(&mut pool.balance, amount, ctx);
    transfer::public_transfer(coin, tx_context::sender(ctx)); // Send to transaction sender (Agent owner)

    // Update score (example)
    // agent::update_score(registry, agent_cap, new_score);
}
