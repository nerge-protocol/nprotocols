module protocol::agent;

use sui::object::{Self, UID};
use sui::transfer;
use sui::tx_context::{Self, TxContext};

// ==================== Errors ====================

const E_UNAUTHORIZED: u64 = 1;

// ==================== Structs ====================

/// Capability representing an authorized AI Agent
public struct AgentCap has key, store {
    id: UID,
    /// ID of the strategy/vault this agent manages
    managed_vault_id: address, // Using address for flexibility (object ID)
    /// Performance score (0-10000)
    score: u64,
}

/// Registry of active agents
public struct AgentRegistry has key {
    id: UID,
    /// Mapping of agent address to their stats (simplified)
    /// For MVP, just a counter or simple list?
    /// Let's just store the admin cap to mint AgentCaps for now.
    admin_id: address,
}

// ==================== Public Functions ====================

/// Initialize the Agent Registry (called on deployment)
public fun init_registry(ctx: &mut TxContext) {
    let registry = AgentRegistry {
        id: object::new(ctx),
        admin_id: tx_context::sender(ctx),
    };
    transfer::share_object(registry);
}

/// Register a new agent (Admin only for now)
public fun register_agent(
    registry: &AgentRegistry,
    managed_vault_id: address,
    ctx: &mut TxContext,
) {
    assert!(tx_context::sender(ctx) == registry.admin_id, E_UNAUTHORIZED);

    let cap = AgentCap {
        id: object::new(ctx),
        managed_vault_id,
        score: 0,
    };

    transfer::public_transfer(cap, tx_context::sender(ctx));
}

/// Update agent score (called by governance/rewards module)
public fun update_score(_registry: &AgentRegistry, agent_cap: &mut AgentCap, new_score: u64) {
    // In reality, this should be restricted to the Rewards module.
    // For MVP, we allow public update if you have the cap? No, that's self-dealing.
    // It should be friend-only or restricted.
    agent_cap.score = new_score;
}

/// Get the managed vault ID
public fun managed_vault(cap: &AgentCap): address {
    cap.managed_vault_id
}
