# Roadmap: FS25_DairyCore

> Ecosystem role: **Dairy and Husbandry** - Part of the Realistic Farming connected suite
> Status: FILLED from the ecosystem audit/baseline.
> Forward-looking only. Shipped history lives in the releases and the ledger.

## How to use this file
- Populate the milestones below as briefs land and builds ship.
- Each item should be small enough to map to a `TODO.md` entry.
- Keep it honest: near-term is committed, mid-term is intended, long-term is aspirational.

## Current baseline
- Version at baseline: v1.0.5.0 (development).
- The mod reads the ecosystem (SoilFertilizer, MarketDynamics, RandomWorldEvents,
  WorkerCosts, FuelCosts, NPCFavor, TaxMod, ProStaff, Ritter RLRM) and rides the
  Time Guard clock. Companion reads are handle-gated + pcall-wrapped and degrade
  to neutral when a mod is absent.

## Near-term (next release cycle)

- [x] Dedicated-server barn discovery (DC-32, 2026-08-18): the Dairy tab showed "no barns" on the dedicated server even with barns placed. `discoverBarns` enumerated through `husbandrySystem:getPlaceablesByFarm`, a method present in no game script, LUADOC or reference, with fallbacks (`hs.placeables` / `hs.husbandries`) that do not exist on the engine-native husbandry system, so discovery found 0 barns on every dedicated server and the update-only network sync could not materialise them on clients. Discovery now iterates the placeable system's own list (`g_currentMission.placeableSystem.placeables`, the table the game itself walks in PlaceableBeehive.lua), reads each placeable's owner via `getOwnerFarmId()`, and retries every 500 ms for 10 s when the list is not yet populated (client join / slow loads). F75's per-owning-farm intent is preserved; the enumerator is now the verified one.
- [x] Esc framework table freeze (Dairy guest, #30, 2026-08-15): the shared 4-bay column grid is restated on every show. Merged; 1.0.5.4.
- [x] Co-op herd advisory (DC-19, **DairyCore half**, 2026-08-14): the gate flag
  `hasHerdAdvisory` is read through the existing `_proStaff` accessor (neutral-false when
  absent); `getHerdAdvisories(farmId)` returns one advisory string per barn needing
  attention, or an empty list below the gate. A barn is flagged when its herd health is at
  or below the needs-attention cutoff (reused from the QUALITY tiering constant, never a
  new number) or its spoilage stage is Ageing or worse (DC-8 lifecycle). Advisory-only: a
  formatted read of state that already exists; no writes, no money, no economics. The
  strings live in `DairyConstants.HERD_ADVISORY`. Bench: 28 assertions in
  `dc19_coop_herd_advisory_test.lua`. **The ProStaff half remains:** the one-row
  `hasHerdAdvisory = 12` FLAGS row + the `ProStaffManager:hasHerdAdvisory` getter on the
  ProStaffCoOp side (SF-40 shape), and the ProStaffApp "Dairy & Logistics" render wiring.
- [ ] FarmTablet Dairy tab / DairyRfPdaGuest consumption of the read model.
- [ ] Contract economics confirmations (DC-10/DC-13): SDK per-cow yield curve, the
  conversion-chain hooks, the exact storage aggregate, the trough consumption trigger.

- [x] Contract archetypes + the sovereign floor anchor (DC-16, 2026-08-14): two new
  contract types are pure data rows in `CONTRACTS.TYPES` (spot_run: 14 days at 1.15x,
  standing_order: 60 days at 0.92x), each gated by `prostaffLevel` like the shipped
  standard row. The settlement floor is re-anchored: `_payContract` now applies
  `max(contractPrice, entry.base * floorFraction)` with `entry.base` pulled from
  MarketDynamics' crash-proof base snapshot, so a market crash cannot drag the
  floor down with it. The ProStaff L20 gate on the floor is dropped until the
  family's `barn.farmId` plumbing lands (neutral settlement). No registry write,
  no `registerPriceModifier` consumer. PROVISIONAL: the archetype gates and the
  floor's magnitudes are SDS-unpinned and defaulted here (see TODO). Built on
  `feat/DC-16-contract-archetypes`, PR into development open.

## Mid-term (this season)
- [ ] The dairy read contract surfaces (DC-14) continue to be the UI contract the
  PDA apps read from; keep the row fields and their server/local/unknown marking
  stable as new systems ship.
- [ ] Contract accrual and the collection scheduling settle their volumes against
  the SDK base `litersPerDay` age-curve once the F12 gate lifts.
- [ ] Family `barn.farmId` plumbing (DC-6/DC-7 fold): when it lands, the ProStaff
  eligibility term that DC-16 intentionally left neutral can gate the floor again,
  this time per-farm instead of farm-blind.

## Long-term / aspirational
- [ ] Per-farm ProStaff-gated eligibility terms across the whole contract menu,
  once the family-level plumbing lands.

## Cross-mod / ecosystem dependencies
- [x] MarketDynamics: consumed as a PULL (`entry.base`) for the settlement floor;
  DairyCore is not a `registerPriceModifier` consumer (DC-16 fold).
- [x] Time Guard: contract accrue-and-settle + the day/hour ticks.
- [x] StateLedger / NetworkSync / SettingsHub bedrock bridges.
- [ ] The ProStaff eligibility term waits on the family `barn.farmId` plumbing
  (DC-6/DC-7), not on this member.

## Deferred / parked
- ProStaff-gated floor eligibility: parked by design until the family plumbing
  lands; settlement is neutral (no ProStaff read) until then.

## DATED ADDITION 2026-08-14 (Fred): DC-17 RITTER GENETICS BUILT

**DC-17, DEEPER USE OF RITTER GENETICS, IS BUILT (modDesc 1.0.5.1).** Milk from
breeding: a dairy farmer who breeds good animals within RealisticLivestock now
sees it in his barn's milk grade, not only in Ritter's animal screen.

**The mechanism (re-scoped fold 2026-08-05):** on each barn's daily tick, when
`RLBridge.active` is true, DC-17 attempts one atomic per-animal read of `health`
and `genetics.productivity` together. If either field fails to read for an animal,
that animal contributes NOTHING to the genetics-weighted average this pass
(all-or-nothing, never partial credit); DC-12's own base score still covers every
animal. When both succeed, the animal's normalized productivity gene enters the
herd average, and the barn score gains
`DairyConstants.HERD.RITTER_GENETICS_WEIGHT` (Engineering-tuned, not measured;
default 25) times that average. The barn is graded on the AVERAGE, not the peak,
so one prize cow does not carry a mediocre herd. The two nonexistent pre-fold
mechanisms (reproduction state, age bands) and the meat-side `genetics.quality`
are CUT, exactly as the fold ruled.

**The flag.** `barn.herdHealthScore_RitterSource` is a strict sub-state of DC-12's
`barn.ritterMode`: true only when the deeper genetics were actually read for at
least one animal. It persists (both save paths and the wire, slot 23 of the 22-to-
23 record) so a surface can distinguish "Ritter supplied the score" from "Ritter
supplied the score AND the deeper genetics were read", and so the uninstall
fallback can detect a barn that lost its source between loads.

**The fallbacks.** All animals missing the atomic read: the score is DC-12's base
score with no genetics term, the flag is false, no divide-by-zero. Ritter removed
mid-save: a barn whose stored flag is true falls back to Standard mode and
publishes a one-time message (save-scoped latch, one per uninstall event, never
twice per barn; a second uninstall/reinstall announces anew).

**F13 read-only fence untouched:** DC-17 adds zero writes into RealisticLivestock.
The per-animal pcall in `RLBridge:computeGeneticsContribution` is deliberately
NOT `safeRead`, so one bad animal cannot trip the whole bridge to Standard mode.

**Bench:** `dc17_ritter_genetics_test.lua`, 32 assertions, 0 failed. Full suite
358/0 across 7 files. **Not yet observed in a running game; in-game acceptance
owed** (mixed-genetics herd, season-by-season breeding climb, uninstall/reinstall
cycle).

