module protocol::gauge;

use protocol::ve_token::{Self, VeGovPosition};
use sui::clock::{Self, Clock};
use sui::event;
use sui::object::{Self, UID, ID};
use sui::transfer;
use sui::tx_context::{Self, TxContext};
use sui::vec_map::{Self, VecMap};
use sui::vec_set::{Self, VecSet};

// ==================== Constants ====================

const EPOCH_DURATION: u64 = 7; // 1 week epochs

// ==================== Structs ====================

/// Gauge controller for emission voting
public struct GaugeController has key {
    id: UID,
    /// Current epoch
    current_epoch: u64,
    /// Total voting power allocated this epoch
    total_vote_power: u64,
    /// Gauge weights per pool
    gauge_weights: VecMap<ID, u64>, // pool_id -> weight
    /// Registered gauges
    registered_gauges: VecSet<ID>,
    /// Last vote epoch per user
    user_last_vote: VecMap<address, u64>,
    /// User votes per gauge
    user_gauge_votes: VecMap<address, VecMap<ID, u64>>,
}

/// Gauge for a specific pool
public struct Gauge has key {
    id: UID,
    pool_id: ID,
    total_weight: u64,
    reward_rate: u64,
    last_update_epoch: u64,
}

// ==================== Events ====================

public struct GaugeVoted has copy, drop {
    voter: address,
    pool_id: ID,
    weight: u64,
    epoch: u64,
}

public struct GaugeWeightUpdated has copy, drop {
    pool_id: ID,
    old_weight: u64,
    new_weight: u64,
    epoch: u64,
}

// ==================== Core Functions ====================

/// Vote for gauge weight allocation
public entry fun vote_for_gauge<GOV>(
    controller: &mut GaugeController,
    ve_position: &VeGovPosition<GOV>,
    pool_id: ID,
    weight_bps: u64, // Basis points of user's veGOV to allocate
    ctx: &mut TxContext,
) {
    assert!(weight_bps <= 10000, E_INVALID_WEIGHT);
    assert!(vec_set::contains(&controller.registered_gauges, &pool_id), E_GAUGE_NOT_REGISTERED);

    let voter = tx_context::sender(ctx);
    let current_epoch = tx_context::epoch(ctx);
    let user_ve_power = ve_token::get_current_ve_balance(ve_position, ctx);

    assert!(user_ve_power > 0, E_NO_VOTING_POWER);

    // Check if user already voted this epoch
    if (vec_map::contains(&controller.user_last_vote, &voter)) {
        let last_vote_epoch = *vec_map::get(&controller.user_last_vote, &voter);
        assert!(current_epoch > last_vote_epoch, E_ALREADY_VOTED_THIS_EPOCH);
    };

    // Calculate vote weight
    let vote_weight = (user_ve_power * weight_bps) / 10000;

    // Update gauge weight
    let current_gauge_weight = if (vec_map::contains(&controller.gauge_weights, &pool_id)) {
        *vec_map::get(&controller.gauge_weights, &pool_id)
    } else {
        0
    };

    let new_gauge_weight = current_gauge_weight + vote_weight;

    if (vec_map::contains(&controller.gauge_weights, &pool_id)) {
        *vec_map::get_mut(&mut controller.gauge_weights, &pool_id) = new_gauge_weight;
    } else {
        vec_map::insert(&mut controller.gauge_weights, pool_id, new_gauge_weight);
    };

    // Update user vote record
    if (vec_map::contains(&controller.user_last_vote, &voter)) {
        *vec_map::get_mut(&mut controller.user_last_vote, &voter) = current_epoch;
    } else {
        vec_map::insert(&mut controller.user_last_vote, voter, current_epoch);
    };

    controller.total_vote_power = controller.total_vote_power + vote_weight;

    event::emit(GaugeVoted {
        voter,
        pool_id,
        weight: vote_weight,
        epoch: current_epoch,
    });

    event::emit(GaugeWeightUpdated {
        pool_id,
        old_weight: current_gauge_weight,
        new_weight: new_gauge_weight,
        epoch: current_epoch,
    });
}

/// Calculate emission allocation for pool
public fun calculate_emission_share(controller: &GaugeController, pool_id: ID): u64 {
    if (controller.total_vote_power == 0) {
        return 0
    };

    let gauge_weight = if (vec_map::contains(&controller.gauge_weights, &pool_id)) {
        *vec_map::get(&controller.gauge_weights, &pool_id)
    } else {
        0
    };

    // Share = (gauge_weight / total_vote_power) * 10000 (in basis points)
    (gauge_weight * 10000) / controller.total_vote_power
}

// ==================== View Functions ====================

/// Get gauge weight for pool
public fun get_gauge_weight(controller: &GaugeController, pool_id: ID): u64 {
    if (vec_map::contains(&controller.gauge_weights, &pool_id)) {
        *vec_map::get(&controller.gauge_weights, &pool_id)
    } else {
        0
    }
}

/// Get total voting power
public fun get_total_vote_power(controller: &GaugeController): u64 {
    controller.total_vote_power
}

// ==================== Error Codes ====================

const E_INVALID_WEIGHT: u64 = 700;
const E_GAUGE_NOT_REGISTERED: u64 = 701;
const E_NO_VOTING_POWER: u64 = 702;
const E_ALREADY_VOTED_THIS_EPOCH: u64 = 703;
