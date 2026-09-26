# Poly39 & XOIO — On-Chain Lottery & Hash Game Contracts

Decentralized lottery and instant hash-betting games running entirely on **Polygon** smart contracts. Fully open-source, verifiable, and auditable on-chain.

## 🎰 Poly39 — On-Chain Lottery

A fully decentralized 5-number lottery on Polygon.

### Contracts

| Contract | Ticket | RNG | Status |
|---|---|---|---|
| `Lotto39_3U_PLUS` | **3 USDT** | **Chainlink VRF v2.5** (verifiable) | **Mainnet (current)** [`0x8b6d8e01e7c3f66e916ed70bba6da86eb0136222`](https://polygonscan.com/address/0x8b6d8e01e7c3f66e916ed70bba6da86eb0136222) — **live (High Stakes + gasless buy)** |
| `Lotto39_2U` | **2 USDT** | **Chainlink VRF v2.5** (verifiable) | **Legacy — retired 2026-09-26** (contract still on Polygon mainnet: [`0xb675247e5ab6fe44D0D7919944F3D4c6F118f5dD`](https://polygonscan.com/address/0xb675247e5ab6fe44D0D7919944F3D4c6F118f5dD)) |

- **Site:** https://poly39.io

### Legacy — 2 USDT `Lotto39_2U` (retired 2026-09-26)

The original 2 USDT contract (`Lotto39_2U`, previously `Lotto39`) is **retired as of 2026-09-26** — the front end now serves the 3 USDT High Stakes game. The contract itself **remains deployed and verified on Polygon mainnet** ([`0xb675247e…f5dD`](https://polygonscan.com/address/0xb675247e5ab6fe44D0D7919944F3D4c6F118f5dD#code)); its source is kept here under [`contracts/legacy/Lotto39_2U.sol`](contracts/legacy/Lotto39_2U.sol) for transparency and auditability.

### 3U — High Stakes (current, Polygon mainnet)

Same lottery, higher stakes — `Lotto39_3U_PLUS` at [`0x8b6d8e01e7c3f66e916ed70bba6da86eb0136222`](https://polygonscan.com/address/0x8b6d8e01e7c3f66e916ed70bba6da86eb0136222) ([verified source](https://polygonscan.com/address/0x8b6d8e01e7c3f66e916ed70bba6da86eb0136222#code)).

| Setting | Value |
|---|---|
| Ticket price | **3 USDT** |
| Prizes | 1st **50%** of pool · 2nd **8%** · 3rd **100 USDT** flat · 4th **6 USDT** flat |
| Limits | 1,500 tickets/round · 500/player · **126 per tx** (max **378 USDT**/tx) |
| RNG | Chainlink VRF v2.5 (same subscription as the 2 USDT contract) |

**Gasless buying (buy-on-behalf):** `buyMultipleTicketsFor(buyer, numbersList, deadline, v, r, s)` lets a relayer
submit a purchase on a player's behalf using an **EIP-2612 permit signature** — the player signs off-chain
(no gas, no POL needed), the relayer pays the gas. The permit is an **exact-amount** approval consumed in the
same transaction (no leftover allowance). A `RelayedPurchase(relayer, buyer, …)` event is emitted for transparency.

### How it works

- Each round lasts **120 minutes** (90 min betting → 5 min draw buffer → 25 min distribution).
- Players pick **5 numbers**; tickets are **2 USDT** each.
- Winning numbers are generated from **Chainlink VRF v2.5** — cryptographically verifiable randomness, provable on-chain.
- Prizes are distributed **automatically by the contract** to winners' wallets — no manual claims.
- **0.5% management fee** per round.
- **Round limits:** max **1,500 tickets/round**, max **500 tickets/player**, max **126 tickets per purchase tx** (anti-monopoly + gas safety).

### Prize structure

| Prize | Match | Share |
|---|---|---|
| 1st | 5/5 | 50% of prize pool |
| 2nd | 4/5 | 8% of prize pool |
| 3rd | 3/5 | Fixed 50 USDT |
| 4th | 2/5 | Fixed 5 USDT |

### Verification

Every draw emits a `DrawExecuted(roundId, uint256[5] winningNumbers)` event — anyone can verify the 5 winning numbers directly on [Polygonscan](https://polygonscan.com/address/0xb675247e5ab6fe44D0D7919944F3D4c6F118f5dD#events). Each VRF request and fulfillment is also recorded on-chain by the [Chainlink VRF Coordinator](https://polygonscan.com/address/0xec0Ed46f36576541C75739E915ADbCb3DE24bD77) — independently auditable.

## ⚡ XOIO — On-Chain Hash Game

Instant betting on the last hexadecimal character of a **Chainlink VRF**-generated random value.

- **Contracts:** `XOIOV2` → `XOIOV3` → `XOIOV4` (latest)
- **Mainnet address (V4):** `0x932B485e0cc57Ca23Ca735984f7846d6A3c638E0`
- **Site:** https://xoio.io

### How it works

- The contract generates a random hash; the **last character** (0–9 or a–f, 16 outcomes) determines the result.
- Three bet types: **EVEN/ODD (×2)**, **DIGIT 0–9 (×15)**, **LETTER A–F (×15)**.
- Max 50 USDT per bet, up to 20 bets per transaction.
- Result is emitted as a `GameResult` event and verifiable on Polygonscan.

## 🀄 Mahjong — On-Chain Taiwanese Mahjong

Four-player Taiwanese (16-tile) mahjong with **on-chain escrow and settlement** on Polygon. The platform never participates in betting — the contract only escrows each player's deposit, keeps a per-seat on-chain ledger, takes a 5% winner management fee, and refunds balances when a table finishes or is aborted.

- **Contract:** `MahjongMatch` (v2.2)
- **Mainnet address:** `0xDc436C37F13eaE63B4dE315FdC0e87529968eD86`
- **Site:** https://xoio.io/mahjong.html

### How it works

- **4 players**, Taiwanese 16-tile rules. A table plays an **East round** (the dealer rotates 4 times), then finalises.
- Players deposit **USDT into the contract (escrow)**; per-round winnings/losses move an internal on-chain ledger — no per-round external transfers.
- Each round's **shuffle seed is written on-chain** (`RoundStarted` event), so any round can be recomputed and audited with the open-source engine.
- **5% management fee** on the winner (accumulated on-chain); balances are **automatically refunded** when a table finishes or is aborted.
- A backend `settler` submits round results (`settleRound`); the tai cap and payout formula are **hard-coded** in the contract.

Source: `contracts/mahjong/MahjongMatch.sol` — specs: `GAME_FLOW_CONTROL_SPEC.md`, `CIRCLE_CONTINUE_SPEC.md`, `MAHJONG_V2_NOTE.md`.

## 📁 Repository structure

```
contracts/
├── poly39/
│   └── Lotto39_3U_PLUS.sol       # Lottery contract (3 USDT High Stakes, Chainlink VRF v2.5, gasless buy) — current
├── legacy/
│   └── Lotto39_2U.sol            # Lottery contract (2 USDT) — retired 2026-09-26; contract still on Polygon mainnet
├── xoio/
│   ├── XOIOV2.sol                # Hash game v2
│   ├── XOIOV3.sol                # Hash game v3
│   ├── XOIOV4.sol                # Hash game v4 (mainnet, Chainlink VRF)
│   ├── XOIOV2_flattened.sol
│   ├── XOIOV3_flattened.sol
│   └── XOIOV4_flattened.sol
└── mahjong/
    ├── MahjongMatch.sol          # 4-player Taiwanese mahjong, on-chain escrow (v2.2)
    ├── GAME_FLOW_CONTROL_SPEC.md
    ├── CIRCLE_CONTINUE_SPEC.md
    └── MAHJONG_V2_NOTE.md
```

## 🔒 Security

- All contracts are **verified on Polygonscan** — source code is public and auditable.
- **Randomness comes from Chainlink VRF v2.5** (Poly39 `Lotto39_3U_PLUS` & XOIO V4) — the industry-standard verifiable random function. Winning numbers/hashes are provably random and tamper-proof; every request and fulfillment is on-chain auditable.
- All funds are held in the smart contracts; payouts execute automatically.

## 📬 Contact

- **Email:** [admin@poly39.io](mailto:admin@poly39.io)
- **X / Twitter:** [@poly39xoio](https://x.com/poly39xoio)
- **Poly39:** https://poly39.io
- **XOIO:** https://xoio.io

## ⚠️ Disclaimer

This repository contains smart contract source code for transparency and audit purposes. Nothing here is financial advice. DeFi and on-chain gaming involve risk — always do your own research.
