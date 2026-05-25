# Stablecoin-toolkit lab — scene contract

`lab/index.html` is a single-file static lab with no build step. It walks a reviewer through the full CR8-USD / MUSD lifecycle on the kcolbchain stablecoin-toolkit. Add a scene by appending one object to the `SCENES` array.

## Scene shape

```js
SCENES.push({
  name: "Your scene title",
  captions: [
    "Markdown-lite caption for step 0 (intro / idle state)",
    "Caption for step 1 — describe the on-chain action with <code>Minter.mint(...)</code>",
    "Caption for step 2",
    // ...
  ],
  setup() {
    // Place agents on the canvas. cx, cy = stage center.
    const cx = W / 2, cy = H / 2 - 20;
    agents = {
      user:       makeAgent({ id: "user", name: "User", role: "KYC tier-1", type: "user", x: cx - 300, y: cy, usdc: 1000 }),
      minter:     makeAgent({ id: "minter", name: "Minter", role: "issuance gateway", type: "contract", x: cx, y: cy }),
      stablecoin: makeAgent({ id: "stablecoin", name: "CR8-USD", role: "ERC-20 · 6 dec", type: "stablecoin", x: cx + 300, y: cy }),
    };
  },
  steps: [
    () => { /* step 0: idle intro, no animation */ },
    (now) => {
      addTx({ from: "user", to: "minter", color: "signal", label: "deposit 1,000 USDC", dur: 1500 });
      byId("minter").flash = 1;
      // schedule follow-ups with setTimeout for staggered effects
    },
    // ...
  ],
});
```

The number of `captions` should match the number of `steps`. The transport auto-advances every `STEP_INTERVAL` (default 1.8s) while playing; users can also `space` (play/pause), `n` (step), `r` (restart), or `←`/`→` to jump scenes.

## Agent types (color / shape defaults)

| type | shape | color | use for |
|---|---|---|---|
| `user` | circle | warm white (`--wallet`) | end-user wallet — depositor, redeemer, holder |
| `stablecoin` | hex | ok-green (`--ok`) | the issued coin itself — CR8-USD, MUSD |
| `treasury` | hex | gold (`--gold`) | fee collector / protocol treasury |
| `reserve` | hex | cyan (`--signal`) | USDC reserve vault / Chainlink PoR reserve |
| `lucidly` | diamond | cyan (`--signal`) | Lucidly syUSD adapter — idle yield destination |
| `oracle` | diamond | purple (`--dsp`) | Chainlink price feed / data oracle |
| `guard` | hex | hot red (`--hot`) | `DepegGuard` state machine |
| `venue` | square | orange (`--warn`) | DEX / CEX / off-chain trading venue |
| `compliance` | circle | hot red (`--hot`) | `ComplianceModule` — KYC / geography gatekeeper |
| `catalog` | hex | pink (`--label`) | `MuzixCatalog` — cap-table source for MUSD pulls |
| `contract` | hex | cyan (`--signal`) | generic toolkit contract (Minter, ReserveManager, etc.) |
| `holder` | circle | warm white (`--wallet`) | cap-table holder claiming a pull-payment |

Override `r`, `color`, or `shape` directly in `makeAgent({...})` if a scene needs something custom (e.g. shrinking a contract to a satellite role with `r: 22`).

## Transaction colors

`addTx({ from, to, color, label, dur, curve, dotSize })`

| color key | use for |
|---|---|
| `accent` / `ok` | money flow — mint, redeem payout, royalty fan-out (the protocol's primary color, green) |
| `signal` | contract → contract reads, USDC moving in/out of vault |
| `dsp` | oracle → contract pushes (Chainlink price, PoR feed) |
| `warn` | venue / DEX action — fills, off-peg prints |
| `hot` | compliance reverts, depeg trips, mint-paused signals |
| `muted` | low-emphasis tx (claims, withdrawals, follow-ups) |

`curve` is a perpendicular offset (px) for parallel paths — use ±20–40 when multiple txs share the same endpoints so they don't overlap.

## Balance / USDC display

Agents can show one of two in-shape numbers:

- `balance: 990` — renders as `$990` in green (stablecoin balance — CR8-USD or MUSD).
- `usdc: 1000` — renders as `$1k` in cyan (USDC / collateral side).

Use one or the other per agent for the in-shape readout; both render in the tooltip if both are set.

## Step pacing rules of thumb

- Keep each step's effect under ~2s. The auto-advance interval is 1.8s; if you need longer, split into two steps or bump `STEP_INTERVAL`.
- Use `setTimeout` within a step for staggered fan-outs — see scene 1's burn-toll fan or scene 5's pull-payment claims.
- At each step boundary, `flash` decays by 70% and `glow` by 40%. Use `byId("x").glow = 1` to **sustain** attention across multiple steps.
- For state-machine scenes (depeg breaker), mutate the agent's `role` string to reflect the new state (`"state: Caution"`) and use `note` for the transient observation reason.

## Naming style

Match the existing voice: short verb-led titles ("Mint with burn toll", "Idle yield park"), captions that read like a protocol-engineer's narration plus the concrete contract call in `<code>`. The goal is for a reviewer (auditor, integrator, regulator) to follow the on-chain flow without prior toolkit context.

Reference real toolkit primitives by name — `Minter.mint`, `Stablecoin.burnFrom`, `ComplianceModule.checkCompliance`, `ReserveManager.pullPorReserve`, `DepegGuard.poke`, `MUSD.batchRoyaltyDistribution`, `claimPayments`. The strings in `<code>` are load-bearing: they tell the reader exactly which function to grep for in `contracts/`.

## Numbers style

Use plausible production numbers, not toy ones:

- Mint toll: **1%** for CR8-USD, **0%** for MUSD.
- Redeem toll: **0.5%** for CR8-USD.
- Default fee bps (per `Minter.sol`): **10 bps = 0.1%** is the floor used in fee-comparison scenes.
- Reserve ratio floor: **10,000 bps (100%)** for US/template, **10,500 (105%)** for India per `config/geographies/`.
- Depeg thresholds (per `DepegGuard.sol` defaults): `cautionBps = 50` (50 bps off peg), `hardBps = 200`, `recoveryCeilingBps = 25`, `minObservationSeconds = 600`, `minRecoverySeconds = 1800`, `hardRedeemHaltSeconds = 12 hours`.
- Accounting decimals: **6** (USDC-style) — match `Stablecoin.decimals()`.
- ISO geography codes per `ComplianceModule.AddressInfo.geography` (`bytes2`): `"US"`, `"IN"`, `"EU"`, restricted like `"KP"`.

If you wander off these defaults, say so explicitly in the caption — reviewers benchmark against `contracts/` source.
