#!/usr/bin/env bash
# Deploys "Beli Pas Turun" (Buy-the-Dip) to Reactive Lasna + Unichain Sepolia.
# Reads DEPLOYER_KEY from .env (never prints it). Prints deployed addresses.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a

LASNA_RPC="https://lasna-rpc.rnk.dev/"
UNI_RPC="https://sepolia.unichain.org/"
UNI_CHAIN_ID=1301
UNI_PROXY=0x775c9B990ADe401060B78D0e98684eEf8d2466C1
WETH_UNI=0x4200000000000000000000000000000000000006

DEPLOYER=$(cast wallet address --private-key "$DEPLOYER_KEY")
echo "Deployer: $DEPLOYER"

deployed() { grep -E '^Deployed to:' | awk '{print $3}'; }

echo "1/7 DipFeed on Unichain Sepolia (initial price \$2500)"
FEED=$(forge create --broadcast --rpc-url "$UNI_RPC" --private-key "$DEPLOYER_KEY" \
  src/DipFeed.sol:DipFeed --constructor-args 250000000000 | deployed)
echo "    FEED=$FEED"

echo "2/7 DipReactive on Lasna (threshold \$2000, buy 10 USDC), funded 2 lREACT"
REACTIVE=$(forge create --broadcast --rpc-url "$LASNA_RPC" --private-key "$DEPLOYER_KEY" \
  --value 2ether src/DipReactive.sol:DipReactive \
  --constructor-args "$FEED" 200000000000 10000000 | deployed)
echo "    REACTIVE=$REACTIVE"

echo "3/7 MockUSDC on Unichain Sepolia"
USDC=$(forge create --broadcast --rpc-url "$UNI_RPC" --private-key "$DEPLOYER_KEY" \
  src/MockERC20.sol:MockERC20 --constructor-args "Mock USDC" "mUSDC" 6 | deployed)
echo "    USDC=$USDC"

echo "4/7 Mint 1000 mock USDC to deployer"
cast send --rpc-url "$UNI_RPC" --private-key "$DEPLOYER_KEY" "$USDC" \
  "mint(address,uint256)" "$DEPLOYER" 1000000000 >/dev/null
echo "    minted"

echo "5/7 Wrap 0.02 Unichain ETH -> WETH"
cast send --rpc-url "$UNI_RPC" --private-key "$DEPLOYER_KEY" --value 0.02ether \
  "$WETH_UNI" "deposit()" >/dev/null
echo "    wrapped"

echo "6/7 DipBuyer on Unichain Sepolia, funded 0.01 ETH for callback gas"
BUYER=$(forge create --broadcast --rpc-url "$UNI_RPC" --private-key "$DEPLOYER_KEY" \
  --value 0.01ether src/DipBuyer.sol:DipBuyer \
  --constructor-args "$UNI_PROXY" "$REACTIVE" "$USDC" "$WETH_UNI" "$FEED" | deployed)
echo "    BUYER=$BUYER"

echo "7/7 Fund DipBuyer (100 USDC + 0.015 WETH) + approve it for 1000 USDC"
cast send --rpc-url "$UNI_RPC" --private-key "$DEPLOYER_KEY" "$USDC" \
  "transfer(address,uint256)" "$BUYER" 100000000 >/dev/null
cast send --rpc-url "$UNI_RPC" --private-key "$DEPLOYER_KEY" "$WETH_UNI" \
  "transfer(address,uint256)" "$BUYER" 15000000000000000 >/dev/null
cast send --rpc-url "$UNI_RPC" --private-key "$DEPLOYER_KEY" "$USDC" \
  "approve(address,uint256)" "$BUYER" 1000000000 >/dev/null
echo "    funded + approved"

echo "8/7 Wire DipBuyer into DipReactive (Lasna)"
cast send --rpc-url "$LASNA_RPC" --private-key "$DEPLOYER_KEY" "$REACTIVE" \
  "setBuyer(address)" "$BUYER" >/dev/null
echo "    wired"

cat > deployments.txt <<EOF
# Beli Pas Turun — Reactive Omni Buildathon (Track 2)
# Deployed: $(date -u +%Y-%m-%dT%H:%M:%SZ)
DEPLOYER=$DEPLOYER
FEED=$FEED
REACTIVE=$REACTIVE
USDC=$USDC
BUYER=$BUYER
WETH_UNI=$WETH_UNI
UNI_PROXY=$UNI_PROXY
EOF

cat <<EOF

Done. Deployments:
  FEED=$FEED
  REACTIVE=$REACTIVE
  USDC=$USDC
  BUYER=$BUYER
EOF
