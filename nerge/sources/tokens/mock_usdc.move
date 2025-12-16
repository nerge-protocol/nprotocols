module protocol::mock_usdc;

use std::option;
use sui::coin;
use sui::transfer;
use sui::tx_context::{Self, TxContext};

public struct MOCK_USDC has drop {}

fun init(witness: MOCK_USDC, ctx: &mut TxContext) {
    let (treasury, metadata) = coin::create_currency(
        witness,
        6,
        b"USDC",
        b"USDC Coin",
        b"Mock USDC for Testing",
        option::none(),
        ctx,
    );
    transfer::public_freeze_object(metadata);
    transfer::public_transfer(treasury, tx_context::sender(ctx));
}
