# TODO: FS25_DairyCore

> Ecosystem role: **Dairy and Husbandry** - Part of the Realistic Farming connected suite
> Status: FILLED from the ecosystem audit/baseline, kept current.
> Convention: `[ ]` open - `[~]` in progress - `[x]` done - `[!]` blocked. Newest at the top of each section.

## Features / enhancements
## Features / enhancements
- [x] Co-op herd advisory (DC-19, **DairyCore half**, 2026-08-14, modDesc 1.0.5.2):
  the gate flag `hasHerdAdvisory` read through the existing `_proStaff` accessor
  (neutral-false when absent), the `getHerdAdvisories(farmId)` getter, and the per-barn
  herd-advisory state computation (health at/below the Standard tier boundary, or spoilage
  stage Ageing/worse). Advisory-only: no write, no money, no economics. 28 assertions in
  `dc19_coop_herd_advisory_test.lua`. Branch `feat/DC-19-coop-herd-advisory` pushed; no PR.
- [x] Contract archetypes + sovereign floor anchor (DC-16, 2026-08-14): two new
  contract rows in `CONTRACTS.TYPES` (spot_run 14d/1.15x, standing_order 60d/0.92x),
  both gated by `prostaffLevel` like the shipped standard row; the settlement floor
  now computes `max(contractPrice, entry.base * floorFraction)` at `_payContract`,
  anchored to MarketDynamics' crash-proof base snapshot pulled at pay time, with no
  ProStaff read (neutral). The old spot-divided-by-spot floor block is deleted.
  Built on `feat/DC-16-contract-archetypes`, PR into development open.

## SDS-unpinned values defaulted by DC-16 (awaiting Arissani's ratification)
- [ ] spot_run / standing_order `prostaffLevel` gates: defaulted to 0 (ladder base,
  same as the shipped standard row). PROVISIONAL until the SDS pins them.
- [ ] `sovereign_floor.floorFraction` (= 0.85, the shipped value) is reused as the
  settlement floor fraction; the brief's mechanism is carried, the magnitude stays
  SDS-owned.

## Bugs
- [x] The sovereign floor floored the live spot and divided by that same spot, so
  the floor crashed exactly when the market crashed (DC-16, 2026-08-14): the floor
  now rides `entry.base`, read as a pull, never the live spot.
- [ ] README conflict markers: `README.md` carries unmerged `<<<<<<< HEAD` /
  `>>>>>>> origin/development` markers on development (FP-1 vs DC-14 bullets).
  Outside DC-16's branch; resolve on its own item.

## Cross-mod integration
- [x] MarketDynamics: pull `entry.base` for the settlement floor; NOT a
  `registerPriceModifier` consumer (the callback context carries no farmId, so a
  per-farm gate cannot express through that door - DC-16 fold).
- [ ] Family `barn.farmId` plumbing (DC-6/DC-7): when it lands, re-add the ProStaff
  eligibility term on the floor as a per-farm read, replacing DC-16's neutral stance.

## Docs / localization
- [ ] Keep all 26 languages in step for any new contract row that surfaces a
  player-facing string.
- [ ] Update README/version on each release.

## Blocked / waiting on
- [!] ProStaff-gated floor eligibility (waits on: the family `barn.farmId` plumbing
  from DC-6/DC-7, named in DC-11's SDS). Until then settlement uses no ProStaff read.
