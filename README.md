# Beli Pas Turun (Buy-the-Dip)

**Reactive Omni Buildathon — Track 2: Set It and Forget It**

A reactive contract that buys ETH with USDC the moment the price dips — no bot, no server, no key online. The network itself watches the price and executes the buy.

## How it works

```
Unichain Sepolia                 Reactive Lasna                Unichain Sepolia
─────────────────                ──────────────                ─────────────────
DipFeed (price feed)
  setPrice($1,900)        ──▶   DipReactive.react()    ──▶    DipBuyer.executeBuy()
  AnswerUpdated event           price < threshold?            swaps 10 USDC → WETH
  (below $2,000)                asks for a callback           sends WETH to owner
```

- **`DipFeed`** — a mock Chainlink `AggregatorV3` price feed. Emits the real `AnswerUpdated` event and implements `latestRoundData()`.
- **`DipReactive`** (Lasna) — subscribes to `AnswerUpdated` from the feed on Unichain Sepolia. When the price drops below the owner's threshold, it requests a callback to `DipBuyer` — once per dip episode. When the price recovers above the threshold, the episode resets and the next dip can buy again.
- **`DipBuyer`** (Unichain Sepolia) — receives the callback through the Reactive callback proxy (authenticated twice: proxy + reactive sender). It swaps USDC for WETH at the feed price from its own reserve and sends the WETH to the owner. It never reverts on a bad callback; it emits `BuyFailed` instead.

## Deployed contracts (testnet, Sourcify-verified)

| Contract | Chain | Address |
| --- | --- | --- |
| `DipFeed` | Unichain Sepolia (1301) | `0xd9Fe58Cf2FEcb10D76d3987160191dF8b567ed6E` |
| `DipReactive` | Reactive Lasna (5318007) | `0xd9Fe58Cf2FEcb10D76d3987160191dF8b567ed6E` |
| `DipBuyer` | Unichain Sepolia (1301) | `0x87B646235794e8C1E4577c18f66346A91A0451AE` |
| `MockUSDC` (mUSDC, 6 dec) | Unichain Sepolia (1301) | `0x8265ab334F71283963b36282820024509B1A659E` |

Settings: threshold **$2,000** (2000e8), buy amount **10 USDC** per dip. `DipReactive` holds 2 lREACT for reactive transactions; `DipBuyer` holds 100 mUSDC + 0.015 WETH + 0.01 ETH for callback gas.

## Demo — the full loop, live on testnet

Price started at $2,500 (above the $2,000 threshold, nothing happens). Then the price was set to $1,900:

| Step | Chain | Transaction |
| --- | --- | --- |
| Origin: `setPrice($1,900)` on `DipFeed` | Unichain Sepolia | `0xe580c41b2444e1e352146a6e0c9d38f1bae988062e7902a708fd044da1b74658` |
| Reactive: `react()` emits `DipDetected` + `BuyRequested`, requests callback | Reactive Lasna | `0xb1247ccc653dfe688151cf454dbb1979c558b9c1fc459c68d457b183cc59fd8e` |
| Callback: `executeBuy()` swaps 10 USDC → 0.0052632 WETH to the owner | Unichain Sepolia | `0x579a0c63a6f57f5063469292b9fd46b1293a031ce25c40cb408fe4e9c819f13c` |

The callback landed **2 blocks (~2 seconds)** after the origin event. The owner received exactly 0.0052632 WETH (10 USDC at $1,900).

## Mock feed vs. the real Chainlink feed

The demo uses `DipFeed`, a mock, because the real Unichain Sepolia ETH/USD feed has a ~24h heartbeat — a mock gives a controllable price for the demo. The contracts are written against the standard `AggregatorV3` interface, so they also work with the real feed:

- Real Unichain Sepolia ETH/USD feed: `0xd9c93081210dFc33326B2af4C2c11848095E6a9a` (8 decimals)

To use it, deploy `DipReactive` with that address as `feed_` instead of `DipFeed`.

## Run the tests

```shell
forge test
```

15 tests: feed events, dip logic (below threshold buys once, recovery resets the episode, wrong topic ignored, `onlySystem` guard), and the buyer swap math (exact WETH at $2,000 and $2,500, bad price / insufficient WETH never revert, proxy + sender auth).

## Deploy (testnet)

```shell
cp .env.example .env   # fill in DEPLOYER_KEY (testnet-only wallet)
bash script/deploy.sh          # deploys everything, or
bash script/deploy-resume.sh   # resumes from step 4 (mint) if a run is interrupted
```

Funding needed (testnet): Sepolia ETH for the lREACT swap (send Sepolia ETH to the Reactive faucet) and the Unichain Sepolia bridge; lREACT on Lasna for the reactive contract; Unichain ETH for the callback contract's gas.

## Stack

- Solidity 0.8.29, Foundry, `reactive-lib-omni` v0.1.0 (Reactive Network Omni, no RVM — single deployment)
- Chains: Reactive Lasna (5318007) + Unichain Sepolia (1301)
- Callback proxy (Unichain Sepolia): `0x775c9B990ADe401060B78D0e98684eEf8d2466C1`

## License

MIT
