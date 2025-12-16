module protocol::clearing;

use nerge_math_lib::math;

// ==================== Public Functions ====================

/// Calculate the uniform clearing price for a batch of orders
/// Returns the price in Q64.64 (Y/X)
/// For MVP, we calculate the price that clears the maximum volume.
/// Simplified: Total X supplied vs Total Y supplied?
/// No, that's just the ratio of pools.
/// We need to match Bids (Buy Y with X) and Asks (Buy X with Y).
///
/// If we have Total X offered (to buy Y) and Total Y offered (to buy X).
/// The market clearing price P (Y/X) is simply Total Y / Total X ?
/// If P = Y_supply / X_supply.
/// Then X_supply buys Y_supply.
/// Everyone gets filled?
/// Only if P satisfies limit prices.
///
/// For MVP, let's assume "Market Orders" (min_out = 0) or simple matching.
/// If we treat all orders as market orders:
/// P_clear = Total Y Offered / Total X Offered.
/// Wait, if I offer 100 X, and you offer 100 Y.
/// P = 100/100 = 1.0.
/// I get 100 Y. You get 100 X. Perfect match.
///
/// What if I offer 100 X, and you offer 50 Y.
/// P = 50/100 = 0.5 (Y/X).
/// I get 50 Y. You get 100 X.
/// My price: I paid 100 X for 50 Y. Price = 0.5.
/// Your price: You paid 50 Y for 100 X. Price = 2.0 (X/Y) = 0.5 (Y/X).
///
/// So for pure market orders, P = Total Y / Total X is the clearing price.
///
/// We will return this simple ratio for now.
public fun calculate_clearing_price(total_x_in: u64, total_y_in: u64): u128 {
    if (total_x_in == 0) return 0; // No bids
    if (total_y_in == 0) return 340282366920938463463374607431768211455; // MAX_U128 - Infinite price (no asks)

    // Price = Y / X
    math::to_q64_64(total_y_in, total_x_in)
}
