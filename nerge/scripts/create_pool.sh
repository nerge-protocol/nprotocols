#!/bin/bash
set -e

PKG="0x61ca7ef8dbe6eb65b3b53d0b973543e5629e90818404eae90d6bf6c2c5ad8470"
POOL_CAP="0x525de88fe6ca6ffcf049ee23fdb4e2183bda942913bcc483be163e6e2ea33259"
GAS_BUDGET="100000000"

echo "🏊 Creating SUI/USDC Pool..."
echo ""
echo "Enter SUI amount (e.g., 100):"
read SUI_AMOUNT

echo "Enter USDC amount (e.g., 150):"
read USDC_AMOUNT

# Convert to smallest units
SUI_MIST=$(echo "$SUI_AMOUNT * 1000000000" | bc)
USDC_MICRO=$(echo "$USDC_AMOUNT * 1000000" | bc)

echo ""
echo "Creating pool with:"
echo "  SUI: $SUI_AMOUNT ($SUI_MIST MIST)"
echo "  USDC: $USDC_AMOUNT ($USDC_MICRO micro)"
echo ""

# Get USDC coins
ADDRESS=$(sui client active-address)
USDC_COINS=$(sui client gas --json | jq -r '.[0].gasCoinId')

# Create pool using PTB
POOL_TX=$(sui client ptb \
  --assign sui_coin @$SUI_MIST \
  --split-coins gas "[sui_coin]" \
  --assign usdc_coin \
  --sui-client-command --package 0x2 --module coin --function mint \
    --type-args ${PKG}::mock_usdc::MOCK_USDC \
    --args --gas-budget $GAS_BUDGET \
  --move-call $PKG::pool::create_pool \
    --type-args 0x2::sui::SUI ${PKG}::mock_usdc::MOCK_USDC \
    --args $POOL_CAP sui_coin.0 usdc_coin 30 5 \
  --gas-budget $GAS_BUDGET --json)

POOL_ID=$(echo $POOL_TX | jq -r '.objectChanges[] | select(.owner.Shared != null) | .objectId')

echo ""
echo "✅ Pool Created!"
echo "Pool ID: $POOL_ID"
echo ""
echo "Update constants.ts with:"
echo "export const SUI_USDC_POOL_ID = \"$POOL_ID\";"
