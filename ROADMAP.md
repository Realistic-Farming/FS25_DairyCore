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
