#!/bin/bash
echo "SUI Market TX: 2TjcRc2Qyz9AuACmyiJTKbEhvW1RKrY1HQQHu6XXk51q"
sui client tx-block 2TjcRc2Qyz9AuACmyiJTKbEhvW1RKrY1HQQHu6XXk51q --json  > sui_market_tx.json

# Find latest USDC market TX
sui client txs --sender 0x96c67386101c33d06b61dcreminder925377a07f204576d8509c8ad6cf605f4793a239 --limit 2 | grep "Transaction Digest" | head -n 1
