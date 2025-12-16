#!/bin/bash

# deploy.sh
# 1. Publish dependencies first (Sui will skip if already published & unchanged)
sui client publish --gas-budget 1000000000 ./nerge_math_lib --skip-dependency-verification --json
sui client publish --gas-budget 1000000000 ./nerge_oracle --skip-dependency-verification --json
sui client publish --gas-budget 1000000000 ./acl_dex_core --skip-dependency-verification --json
sui client publish --gas-budget 1000000000 ./p2ph_lending_core --skip-dependency-verification --json

# 2. Finally publish the main protocol
sui client publish --gas-budget 1000000000 ./nerge --skip-dependency-verification --json
