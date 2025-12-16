module protocol::dao;

use protocol::ve_token::{Self, VeGovPosition, VeGovState};
use std::string::{Self, String};
use sui::clock::{Self, Clock};
use sui::event;
use sui::object::{Self, UID, ID};
use sui::transfer;
use sui::tx_context::{Self, TxContext};
use sui::vec_map::{Self, VecMap};

// ==================== Constants ====================

const VOTING_PERIOD_EPOCHS: u64 = 7; // ~1 week
const EXECUTION_DELAY_EPOCHS: u64 = 2; // ~2 days
const QUORUM_BPS: u64 = 2000; // 20%
const APPROVAL_THRESHOLD_BPS: u64 = 6000; // 60%

// ==================== Structs ====================

/// DAO governance proposal
public struct Proposal has key {
    id: UID,
    /// Proposal title
    title: String,
    /// Proposal description
    description: String,
    /// Proposer
    proposer: address,
    /// Voting start epoch
    voting_start: u64,
    /// Voting end epoch
    voting_end: u64,
    /// Execution epoch (after timelock)
    execution_epoch: u64,
    /// Votes for
    votes_for: u64,
    /// Votes against
    votes_against: u64,
    /// Voters (to prevent double voting)
    voters: VecMap<address, u64>,
    /// Proposal state
    state: u8, // 0=Active, 1=Succeeded, 2=Defeated, 3=Executed, 4=Canceled
    /// Required quorum
    quorum_required: u64,
    /// Actions to execute (serialized)
    actions: vector<u8>,
}

/// Voting receipt
public struct VoteReceipt has key, store {
    id: UID,
    proposal_id: ID,
    voter: address,
    support: bool,
    voting_power: u64,
    vote_epoch: u64,
}

/// Proposal creation capability
public struct ProposalCreationCap has key {
    id: UID,
    min_ve_balance_required: u64,
}

// ==================== Events ====================

public struct ProposalCreated has copy, drop {
    proposal_id: ID,
    proposer: address,
    title: String,
    voting_start: u64,
    voting_end: u64,
}

public struct VoteCast has copy, drop {
    proposal_id: ID,
    voter: address,
    support: bool,
    voting_power: u64,
}

public struct ProposalExecuted has copy, drop {
    proposal_id: ID,
    execution_epoch: u64,
}

public struct ProposalCanceled has copy, drop {
    proposal_id: ID,
    canceler: address,
}

// ==================== Core Functions ====================

/// Create a new governance proposal
public fun create_proposal<GOV>(
    ve_position: &VeGovPosition<GOV>,
    ve_state: &VeGovState<GOV>,
    cap: &ProposalCreationCap,
    title: vector<u8>,
    description: vector<u8>,
    actions: vector<u8>,
    ctx: &mut TxContext,
): Proposal {
    // Check proposer has enough veGOV
    let current_ve = ve_token::get_current_ve_balance(ve_position, ctx);
    assert!(current_ve >= cap.min_ve_balance_required, E_INSUFFICIENT_VE_BALANCE);

    let current_epoch = tx_context::epoch(ctx);
    let voting_start = current_epoch + 1; // Start next epoch
    let voting_end = voting_start + VOTING_PERIOD_EPOCHS;
    let execution_epoch = voting_end + EXECUTION_DELAY_EPOCHS;

    // Calculate quorum based on total veGOV supply
    let total_ve_supply = ve_token::get_total_ve_supply(ve_state);
    let quorum_required = (total_ve_supply * QUORUM_BPS) / 10000;

    let proposal = Proposal {
        id: object::new(ctx),
        title: string::utf8(title),
        description: string::utf8(description),
        proposer: tx_context::sender(ctx),
        voting_start,
        voting_end,
        execution_epoch,
        votes_for: 0,
        votes_against: 0,
        voters: vec_map::empty(),
        state: 0, // Active
        quorum_required,
        actions,
    };

    event::emit(ProposalCreated {
        proposal_id: object::id(&proposal),
        proposer: tx_context::sender(ctx),
        title: proposal.title,
        voting_start,
        voting_end,
    });

    proposal
}

/// Cast vote on proposal
public fun cast_vote<GOV>(
    proposal: &mut Proposal,
    ve_position: &VeGovPosition<GOV>,
    support: bool,
    ctx: &mut TxContext,
): VoteReceipt {
    let current_epoch = tx_context::epoch(ctx);
    let voter = tx_context::sender(ctx);

    // Check voting period is active
    assert!(
        current_epoch >= proposal.voting_start &&
        current_epoch < proposal.voting_end,
        E_VOTING_NOT_ACTIVE,
    );
    assert!(proposal.state == 0, E_PROPOSAL_NOT_ACTIVE);

    // Check voter hasn't voted already
    assert!(!vec_map::contains(&proposal.voters, &voter), E_ALREADY_VOTED);

    // Get voting power (current veGOV balance)
    let voting_power = ve_token::get_current_ve_balance(ve_position, ctx);
    assert!(voting_power > 0, E_NO_VOTING_POWER);

    // Record vote
    if (support) {
        proposal.votes_for = proposal.votes_for + voting_power;
    } else {
        proposal.votes_against = proposal.votes_against + voting_power;
    };

    vec_map::insert(&mut proposal.voters, voter, voting_power);

    event::emit(VoteCast {
        proposal_id: object::id(proposal),
        voter,
        support,
        voting_power,
    });

    VoteReceipt {
        id: object::new(ctx),
        proposal_id: object::id(proposal),
        voter,
        support,
        voting_power,
        vote_epoch: current_epoch,
    }
}

/// Finalize proposal after voting ends
public entry fun finalize_proposal(proposal: &mut Proposal, ctx: &TxContext) {
    let current_epoch = tx_context::epoch(ctx);

    assert!(current_epoch >= proposal.voting_end, E_VOTING_STILL_ACTIVE);
    assert!(proposal.state == 0, E_PROPOSAL_NOT_ACTIVE);

    let total_votes = proposal.votes_for + proposal.votes_against;

    // Check quorum
    if (total_votes < proposal.quorum_required) {
        proposal.state = 2; // Defeated
        return
    };

    // Check approval threshold
    let approval_rate = (proposal.votes_for * 10000) / total_votes;

    if (approval_rate >= APPROVAL_THRESHOLD_BPS) {
        proposal.state = 1; // Succeeded
    } else {
        proposal.state = 2; // Defeated
    };
}

/// Execute passed proposal (admin function in production)
public entry fun execute_proposal(proposal: &mut Proposal, ctx: &TxContext) {
    let current_epoch = tx_context::epoch(ctx);

    assert!(proposal.state == 1, E_PROPOSAL_NOT_SUCCEEDED);
    assert!(current_epoch >= proposal.execution_epoch, E_TIMELOCK_NOT_EXPIRED);

    // In production, this would decode and execute the actions
    // For now, we just mark as executed
    proposal.state = 3; // Executed

    event::emit(ProposalExecuted {
        proposal_id: object::id(proposal),
        execution_epoch: current_epoch,
    });
}

// ==================== View Functions ====================

/// Get proposal status
public fun get_proposal_status(proposal: &Proposal): (u8, u64, u64, u64) {
    (proposal.state, proposal.votes_for, proposal.votes_against, proposal.quorum_required)
}

/// Check if address has voted
public fun has_voted(proposal: &Proposal, voter: address): bool {
    vec_map::contains(&proposal.voters, &voter)
}

/// Get voting power used by voter
public fun get_vote_power(proposal: &Proposal, voter: address): u64 {
    if (vec_map::contains(&proposal.voters, &voter)) {
        *vec_map::get(&proposal.voters, &voter)
    } else {
        0
    }
}

// ==================== Error Codes ====================

const E_INSUFFICIENT_VE_BALANCE: u64 = 600;
const E_VOTING_NOT_ACTIVE: u64 = 601;
const E_VOTING_STILL_ACTIVE: u64 = 602;
const E_ALREADY_VOTED: u64 = 603;
const E_NO_VOTING_POWER: u64 = 604;
const E_PROPOSAL_NOT_ACTIVE: u64 = 605;
const E_PROPOSAL_NOT_SUCCEEDED: u64 = 606;
const E_TIMELOCK_NOT_EXPIRED: u64 = 607;
