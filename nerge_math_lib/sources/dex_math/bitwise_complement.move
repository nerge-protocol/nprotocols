module nerge_math_lib::bitwise_complement;

const MAX_U8: u8 = 0xFF;
const MAX_U16: u16 = 0xFFFF;
const MAX_U32: u32 = 0xFFFFFFFF;
const MAX_U64: u64 = 0xFFFFFFFFFFFFFFFF;
const MAX_U128: u128 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFu128;
const MAX_U256: u256 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;

public fun bitwise_complement_u8(value: u8): u8 {
    MAX_U8 ^ value
}

public fun bitwise_complement_u16(value: u16): u16 {
    MAX_U16 ^ value
}

public fun bitwise_complement_u32(value: u32): u32 {
    MAX_U32 ^ value
}

public fun bitwise_complement_u64(value: u64): u64 {
    MAX_U64 ^ value
}

public fun bitwise_complement_u128(value: u128): u128 {
    MAX_U128 ^ value
}

public fun bitwise_complement_u256(value: u256): u256 {
    MAX_U256 ^ value
}
