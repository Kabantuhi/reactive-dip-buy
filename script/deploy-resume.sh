#!/usr/bin/env bash
# Resumes the Beli Pas Turun deploy from step 4 (mint) with sleeps between
# transactions so the public RPC's nonce view catches up. Reads DEPLOYER_KEY
# from .env (never prints it).
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a

LASNA_RPC="https://lasna-rpc.rnk.dev/"
UNI_RPC="https://sepolia.unichain.org/"
UNI_PROXY=0x775c9B990ADe401060B78D0e98684eEf8d2466C1
WETH_UNI=0x4200000000000000000000000000000000000006
FEED=0xd9Fe58Cf2FEcb10D76d3987160191dF8b567ed6E
REACTIVE=0xd9Fe58Cf2FEcb10D76d3987160191dF8b567ed6E
USDC=0x8265ab334F71283963b36282820024509B1A659E

DEPLOYER=$(cast wallet address --private-key "$DEPLOYER_KEY")
deployed() { grep -E '^Deployed to:' | awk '{print $3}'; }

echo "4/7 Mint 1000 mock USDC to deployer"
cast send --rpc-url "$UNI_RPC" --private-key "$DEPLOYER_KEY" "$USDC" \
  "mint(address,uint256)" "$DEPLOYER" 1000000000 >/dev/null
sleep 5

echo "5/7 Wrap 0.02 Unichain ETH -> WETH"
cast send --rpc-url "$UNI_RPC" --private-key "$DEPLOYER_KEY" --value 0.02ether \
  "$WETH_UNI" "deposit()" >/dev/null
sleep 5

echo "6/7 DipBuyer on Unichain Sepolia, funded 0.01 ETH for callback gas"
BUYER=$(forge create --broadcast --rpc-url "$UNI_RPC" --private-key "$DEPLOYER_KEY" \
  --value 0.01ether src/DipBuyer.sol:DipBuyer \
  --constructor-args "$UNI_PROXY" "$REACTIVE" "$USDC" "$WETH_UNI" "$FEED" | deployed)
echo "    BUYER=$BUYER"
sleep 5

echo "7/7 Fund DipBuyer (100 USDC + 0.015 WETH) + approve it for 1000 USDC"
cast send --rpc-url "$UNI_RPC" --private-key "$DEPLOYER_KEY" "$USDC" \
  "transfer(address,uint256)" "$BUYER" 100000000 >/dev/null
sleep 5
cast send --rpc-url "$UNI_RPC" --private-key "$DEPLOYER_KEY" "$WETH_UNI" \
  "transfer(address,uint256)" "$BUYER" 15000000000000000 >/dev/null
sleep 5
cast send --rpc-url "$UNI_RPC" --private-key "$DEPLOYER_KEY" "$USDC" \
  "approve(address,uint256)" "$BUYER" 1000000000 >/dev/null
sleep 5

echo "8/7 Wire DipBuyer into DipReactive (Lasna)"
cast send --rpc-url "$LASNA_RPC" --private-key "$DEPLOYER_KEY" "$REACTIVE" \
  "setBuyer(address)" "$BUYER" >/dev/null
sleep 5

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
