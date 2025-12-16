// ============================================================================
// 2. RL ORACLE MODULE (OFF-CHAIN RL → ON-CHAIN)
// ============================================================================

module p2ph_lending_core::rl_oracle;

use std::vector;
use sui::clock::{Self, Clock};
use sui::event;
use sui::object::{Self, UID};
use sui::tx_context::{Self, TxContext};

// Import lending module for RateParameters - circular dependency if we import lending here
// The doc imports p2ph::lending.
// To avoid circular dependency, we might need to define RateParameters in a shared module or here.
// However, looking at the doc, rl_oracle imports lending, and lending imports rl_oracle.
// Move doesn't support circular dependencies.
// We need to decouple them.
// Option 1: Define shared structs in a separate module.
// Option 2: rl_oracle doesn't need to know about RateParameters struct, just generic vector<u8> or similar?
// The doc says: `use p2ph::lending;` and `public fun action_to_rate_params(...): lending::RateParameters`.
// And lending uses `use p2ph::rl_oracle;` and `public entry fun update_rates_via_rl(..., rl_oracle: &rl_oracle::RLOracle, ...)`

// I will create a `protocol::p2ph_types` module to hold shared structs if needed,
// OR I will define RateParameters in lending and have rl_oracle NOT import lending,
// but instead return raw values that lending converts.

// But wait, the doc explicitly shows the circular import in the code blocks.
// "module p2ph::lending { ... use p2ph::rl_oracle; ... }"
// "module p2ph::rl_oracle { ... use p2ph::lending; ... }"
// This is invalid in Move.

// I will refactor to avoid circular dependency.
// I'll put RateParameters in `rl_oracle` or a third module.
// Since `lending` is the main consumer, maybe `RateParameters` belongs there.
// `rl_oracle` produces `action_vector`. `lending` consumes it.
// The `action_to_rate_params` function in `rl_oracle` creates a dependency on `lending`.
// I should move `action_to_rate_params` to `lending` module or a utility module.
// `rl_oracle` should be independent.

// Let's implement `rl_oracle` without dependency on `lending`.

// ===================== STRUCTS =====================

/// RL Oracle that signs rate update decisions
public struct RLOracle has key {
    id: UID,
    owner: address,
    model_version: u64,
    model_hash: vector<u8>, // Hash of RL model for verification
    is_active: bool,
    // Current state encoding
    current_state: StateVector,
    // Last decision
    last_decision: RLDecision,
    // Statistics
    total_decisions: u64,
    avg_confidence: u64,
}

/// Encoded state vector for RL (15 features)
public struct StateVector has copy, drop, store {
    values: vector<u64>, // 15 values, each scaled appropriately
    timestamp: u64,
}

/// RL decision with action vector
public struct RLDecision has copy, drop, store {
    action_vector: vector<u64>, // [Δr0, Δr1, Δr2, ΔU*] scaled
    state_vector: StateVector,
    reward_estimate: u64,
    confidence: u64,
    signature: vector<u8>,
    timestamp: u64,
}

/// Event: RL model updated
public struct RLModelUpdateEvent has copy, drop {
    old_model_hash: vector<u8>,
    new_model_hash: vector<u8>,
    version: u64,
    timestamp: u64,
}

// ===================== INITIALIZATION =====================

public fun create_rl_oracle(
    owner: &signer, // In Sui we use TxContext for sender usually, but here maybe just pass address?
    // The doc uses &signer which is Aptos/Move std style. Sui uses TxContext.
    // I'll adapt to Sui style.
    initial_model_hash: vector<u8>,
    ctx: &mut TxContext,
): RLOracle {
    RLOracle {
        id: object::new(ctx),
        owner: tx_context::sender(ctx), // Assuming owner is sender
        model_version: 1,
        model_hash: initial_model_hash,
        is_active: true,
        current_state: StateVector {
            values: vector::empty<u64>(),
            timestamp: tx_context::epoch(ctx), // Using epoch as timestamp proxy or clock? Doc uses timestamp_ms
        },
        last_decision: create_empty_decision(),
        total_decisions: 0,
        avg_confidence: 0,
    }
}

fun create_empty_decision(): RLDecision {
    RLDecision {
        action_vector: vector::empty<u64>(),
        state_vector: StateVector {
            values: vector::empty<u64>(),
            timestamp: 0,
        },
        reward_estimate: 0,
        confidence: 0,
        signature: vector::empty<u8>(),
        timestamp: 0,
    }
}

// ===================== RL DECISION SUBMISSION =====================

/// Submit new RL decision (called by off-chain RL service)
public entry fun submit_decision(
    oracle: &mut RLOracle,
    action_vector: vector<u64>,
    state_values: vector<u64>,
    state_timestamp: u64,
    reward_estimate: u64,
    confidence: u64,
    signature: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(oracle.is_active, 1);
    assert!(tx_context::sender(ctx) == oracle.owner, 2);

    let state_vector = StateVector {
        values: state_values,
        timestamp: state_timestamp,
    };

    // Verify signature (RL service signs decision)
    assert!(
        verify_signature(
            &action_vector,
            &state_vector,
            reward_estimate,
            confidence,
            &signature,
            oracle.owner,
        ),
        3,
    );

    // Validate action vector (4 elements: [Δr0, Δr1, Δr2, ΔU*])
    assert!(vector::length(&action_vector) == 4, 4);

    // Validate state vector (15 elements)
    assert!(vector::length(&state_vector.values) == 15, 5);

    // Create decision
    let decision = RLDecision {
        action_vector,
        state_vector,
        reward_estimate,
        confidence,
        signature,
        timestamp: clock::timestamp_ms(clock),
    };

    // Update oracle state
    oracle.last_decision = decision;
    oracle.current_state = state_vector;
    oracle.total_decisions = oracle.total_decisions + 1;

    // Update average confidence (EMA)
    let alpha = 100; // Learning rate (scaled)
    oracle.avg_confidence = (alpha * confidence + (1000 - alpha) * oracle.avg_confidence) / 1000;
}

// Removed action_to_rate_params to avoid circular dependency

// ===================== VERIFICATION =====================

/// Verify RL decision is valid for protocol
public fun verify_decision(oracle: &RLOracle, clock: &Clock): bool {
    if (!oracle.is_active) return false;

    // Check that we have a recent decision
    let decision = &oracle.last_decision;
    let current_time = clock::timestamp_ms(clock);

    // Decision shouldn't be too old (e.g., < 1 hour)
    if (current_time - decision.timestamp > 3600000) {
        return false;
    };

    // Check confidence threshold
    if (decision.confidence < 5000) {
        // 50% confidence minimum
        return false;
    };

    true
}

fun verify_signature(
    _action_vector: &vector<u64>,
    _state_vector: &StateVector,
    _reward_estimate: u64,
    _confidence: u64,
    signature: &vector<u8>,
    _owner: address,
): bool {
    // In production: use proper cryptographic signature verification
    // This is simplified for illustration

    // For now, just check signature length
    vector::length(signature) > 0
}

// ===================== GETTER FUNCTIONS =====================

public fun get_action_vector(oracle: &RLOracle): vector<u64> {
    oracle.last_decision.action_vector
}

public fun get_state_vector(oracle: &RLOracle): vector<u64> {
    oracle.current_state.values
}

public fun get_reward_estimate(oracle: &RLOracle): u64 {
    oracle.last_decision.reward_estimate
}

public fun get_confidence(oracle: &RLOracle): u64 {
    oracle.last_decision.confidence
}

// ===================== ADMIN FUNCTIONS =====================

public entry fun update_model(
    oracle: &mut RLOracle,
    new_model_hash: vector<u8>,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert!(tx_context::sender(ctx) == oracle.owner, 10);

    let old_hash = oracle.model_hash;

    oracle.model_hash = new_model_hash;
    oracle.model_version = oracle.model_version + 1;

    event::emit(RLModelUpdateEvent {
        old_model_hash: old_hash,
        new_model_hash: new_model_hash,
        version: oracle.model_version,
        timestamp: clock::timestamp_ms(clock),
    });
}

public entry fun set_active(oracle: &mut RLOracle, active: bool, ctx: &TxContext) {
    assert!(tx_context::sender(ctx) == oracle.owner, 11);
    oracle.is_active = active;
}

public entry fun transfer_ownership(oracle: &mut RLOracle, new_owner: address, ctx: &TxContext) {
    assert!(tx_context::sender(ctx) == oracle.owner, 12);
    oracle.owner = new_owner;
}

#[test_only]
public fun create_for_testing(ctx: &mut TxContext): RLOracle {
    RLOracle {
        id: object::new(ctx),
        owner: tx_context::sender(ctx),
        model_version: 1,
        model_hash: vector::empty(),
        is_active: true,
        current_state: StateVector {
            values: vector::empty(),
            timestamp: 0,
        },
        last_decision: create_empty_decision(),
        total_decisions: 0,
        avg_confidence: 0,
    }
}

#[test_only]
public fun share_for_testing(oracle: RLOracle) {
    transfer::share_object(oracle);
}
