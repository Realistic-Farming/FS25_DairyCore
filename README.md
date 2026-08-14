# FS25_DairyCore

**Realistic Farming - Dairy Core** is a per-barn dairy management layer for the Realistic Farming mod ecosystem. It reads the ecosystem (SoilFertilizer, MarketDynamics, RandomWorldEvents, WorkerCosts, FuelCosts, NPCFavor, TaxMod, ProStaff, and Ritter's Realistic Livestock) and rides the shared **Time Guard** economic clock. Every cross-mod edge is handle-gated and pcall-wrapped, so it degrades gracefully when a companion mod is absent.

**Version:** 1.0.3.0

## What it does

- **Herd health**, two modes decided once at mission load:
  - *Standard*: the base-game `getGlobalProductionFactor()` plus SoilFertilizer feed-field modifiers (organic matter, N/P/K balance, weed/pest pressure, legume rotation).
  - *Ritter*: a per-animal genetics + health composite via `RLBridge` when Realistic Livestock is present. Any read failure trips cleanly back to Standard (F13: DairyCore never writes into Ritter).
- **Milk quality tiers** (Premium / Standard / Reduced / Poor) from the herd health score.
- **Time-based spoilage** (Fresh / Ageing / At Risk / Condemned), evaluated on the Time Guard hour tick from fractional elapsed days since the last collection (DC-8). A barn on a precise 24h cadence stays Fresh the whole round; a barn nobody collects ages continuously to Condemned. The band crosses as an l10n key, and the contract settlement pays the effective (post-spoilage) tier.
- **The milk round (DC-9)**: the mod now NOTICES milk leaving a barn whichever way it went. A tanker or an AI haul is detected from the raw storage level (ungated, F108-safe) and credited as `self`/`hauled`; a standing rota (a WorkerCosts worker assigned per barn, admin-gated) and the office sale actively remove, price and credit milk with their own sources (`rota`/`office`). The freshness clock now actually ticks.
- **The office sale (DC-21)**: sell milk from an admin action without a truck. Reads the level, prices it through the spot market, applies a tunable administrative margin (SettingsHub), removes the milk by the standard removal path and credits the money.
- **Administrative collection scheduling** with a WorkerCosts skill read (no AI pathing).
- **Feed-source fields**: player-designated per barn, with the SF `diseaseDiscovered` reveal gate (a free flag names *which* field is at risk; the disease name surfaces only after a scout or the paid report).
- **The dairy read contract (DC-14)**: the published per-barn row never presents a default as a fact. Every field marks which machine produced it (server / local / unknown), the sync transport carries the fields a client would otherwise guess at (the active contract, its progress band, the spoilage key, store-full, the owning farm, the feed signal), and quality and spoilage cross as l10n keys, never English display text.
- **Read-only mycotoxin penalty** to herd health (both modes), received from the disease broadcast.
- **Dairy contracts** (4 types) that settle on the Time Guard clock via `registerAccrual`: server-only, idempotent across save/reload. Base-game `addMoney` pays the income; TaxMod `recordExpense` is audit-only.

## Handles

```
g_currentMission.dairyCoreManager   -- cross-mod handle, set in Mission00.load, nil on delete
g_dairyCoreManager                  -- getfenv(0) same-mod fallback
```

## Core API connections (delegate-when-present, neutral when absent)

- **Time Guard** — day/hour ticks + the contract accrue-and-settle scheduler.
- **StateLedger** — barn + contract state (own-XML fallback `FS25_DairyCore.xml` when absent).
- **NetworkSync** — barn state sync to clients.
- **SettingsHub** — four admin settings (enable, default collection interval, spoilage, contracts).

## Notes

- Zero Precision Farming: if `FS25_precisionFarming` is present, DairyCore stands down.
- Contract volume figures are tunable placeholders gated on the SDK per-cow yield curve (F12).
- 26 languages ship from day one. Console command: `dairyStatus`.
