#!/bin/bash
set -e

# Configuration
PKG="0x61ca7ef8dbe6eb65b3b53d0b973543e5629e90818404eae90d6bf6c2c5ad8470"
MARKET_CAP="0x4a7f5d4b3c0e85083c66900bbabb86c5e113f73cb98a2cc0fc7da4fe6222ac48"
USDC_TREASURY="0x80cb7b551e90eefa72e83c5c6c05901aa1ba56bfc1e7a7215e291cfbae87715d"
SUI_ORACLE="0x8e53a4e68d40fcb8ae5f670c2b0d4d355cc2ab94057b8817fcc79d8b0e7a2c2a"
GAS_BUDGET="100000000"
CLOCK="0x6"
ADDRESS=$(sui client active-address)

echo "📦 Package: $PKG"
echo "👤 Address: $ADDRESS"

# Create USDC Oracle
echo "🔮 Creating USDC Oracle..."
USDC_ORACLE_TX=$(sui client call --package $PKG --module oracle --function create_price_feed \
  --args "USDC/USD" 1 3 60000 \
  --gas-budget $GAS_BUDGET --json)

USDC_ORACLE=$(echo $USDC_ORACLE_TX | jq -r '.objectChanges[] | select(.objectType | contains("PriceFeed")) | .objectId')
echo "   USDC Oracle: $USDC_ORACLE"

# Register and submit SUI price
echo "🏷️  Registering SUI Oracle..."
SUI_REG_TX=$(sui client call --package $PKG --module oracle --function register_oracle \
  --args $SUI_ORACLE \
  --gas-budget $GAS_BUDGET --json)
SUI_REG=$(echo $SUI_REG_TX | jq -r '.objectChanges[] | select(.objectType | contains("OracleRegistration")) | .objectId')
echo "   SUI Registration: $SUI_REG"

# Submit SUI price ($1.50 = High:1, Low:9223372036854775808)
sui client call --package $PKG --module oracle --function submit_price_split \
  --args $SUI_ORACLE $SUI_REG 1 9223372036854775808 10000 $CLOCK \
  --gas-budget $GAS_BUDGET > /dev/null
echo "   ✅ SUI Price submitted ($1.50)"

# Register and submit USDC price  
echo "🏷️  Registering USDC Oracle..."
USDC_REG_TX=$(sui client call --package $PKG --module oracle --function register_oracle \
  --args $USDC_ORACLE \
  --gas-budget $GAS_BUDGET --json)
USDC_REG=$(echo $USDC_REG_TX | jq -r '.objectChanges[] | select(.objectType | contains("OracleRegistration")) | .objectId')

# Submit USDC price ($1.00 = High:1, Low:0)
sui client call --package $PKG --module oracle --function submit_price_split \
  --args $USDC_ORACLE $USDC_REG 1 0 10000 $CLOCK \
  --gas-budget $GAS_BUDGET > /dev/null
echo "   ✅ USDC Price submitted ($1.00)"

# Create SUI Market
echo "🏦 Creating SUI Market..."
SUI_MARKET_TX=$(sui client call --package $PKG --module lending_market --function create_market \
  --type-args 0x2::sui::SUI \
  --args $MARKET_CAP 7500 8000 500 1500 20 100 1000 8000 $SUI_ORACLE $CLOCK \
  --gas-budget $GAS_BUDGET --json)
SUI_MARKET=$(echo $SUI_MARKET_TX | jq -r '.objectChanges[] | select(.objectType | contains("LendingMarket")) | .objectId')
echo "   SUI Market: $SUI_MARKET"

# Create USDC Market
echo "🏦 Creating USDC Market..."
USDC_MARKET_TX=$(sui client call --package $PKG --module lending_market --function create_market \
  --type-args ${PKG}::mock_usdc::MOCK_USDC \
  --args $MARKET_CAP 7500 8000 500 1500 20 100 1000 8000 $USDC_ORACLE $CLOCK \
  --gas-budget $GAS_BUDGET --json)
USDC_MARKET=$(echo $USDC_MARKET_TX | jq -r '.objectChanges[] | select(.objectType | contains("LendingMarket")) | .objectId')
echo "   USDC Market: $USDC_MARKET"

# Mint USDC
echo "💰 Minting USDC..."
sui client call --package 0x2 --module coin --function mint_and_transfer \
  --type-args ${PKG}::mock_usdc::MOCK_USDC \
  --args $USDC_TREASURY 1000000000000 $ADDRESS \
  --gas-budget $GAS_BUDGET > /dev/null
echo "   Minted 1,000,000 USDC"

# --- Final Report ---
echo "✅ Deployment Complete!"
echo "--------------------------------------------------"
echo "Protocol Package: $PROTOCOL_PACKAGE_ID"
echo "Sui Market: $SUI_MARKET"
echo "USDC Market: $USDC_MARKET"

# Write constants.ts
cat > ../frontend/src/lib/contracts/constants.ts <<EOL
export const NETWORK = 'localnet';
export const PROTOCOL_PACKAGE_ID = '$PKG';
export const SUI_MARKET_OBJECT_ID = '$SUI_MARKET';
export const USDC_MARKET_OBJECT_ID = '$USDC_MARKET';
export const SUI_ORACLE_OBJECT_ID = '$SUI_ORACLE';
export const USDC_ORACLE_OBJECT_ID = '$USDC_ORACLE';

export const MODULES = {
  lending_market: 'lending_market',
  pool: 'pool',
  mock_usdc: 'mock_usdc',
  faucet: 'faucet',
  oracle: 'oracle',
};

export const COINS = {
  SUI: '0x2::sui::SUI',
  MOCK_USDC: \`\${PROTOCOL_PACKAGE_ID}::mock_usdc::MOCK_USDC\`,
};
EOL

echo ""
echo "📝 Updated frontend/src/lib/contracts/constants.ts"
