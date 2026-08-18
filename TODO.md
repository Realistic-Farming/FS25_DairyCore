# TODO: FS25_DairyCore

> Ecosystem role: **Dairy and Husbandry** - Part of the Realistic Farming connected suite
> Status: FILLED from the ecosystem audit/baseline, kept current.
> Convention: `[ ]` open - `[~]` in progress - `[x]` done - `[!]` blocked. Newest at the top of each section.

## Features / enhancements

- [x] Esc framework table freeze (Dairy guest, #30): shared grid restated per show; 1.0.5.4.
- [~] In-game: Dairy table keeps its columns after visiting another Esc guest in the same session.
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
- [x] DC-32 (2026-08-18): Dairy tab showed "no barns" on the dedicated server. `discoverBarns` enumerated via `husbandrySystem:getPlaceablesByFarm` (unverifiable, absent from every reference and the game scripts) with fallbacks that do not exist on the engine-native system, so discovery found 0 barns; the network sync is update-only and could not materialise them on clients. Fix: enumerate `g_currentMission.placeableSystem.placeables` (the verified table, walked by PlaceableBeehive.lua), owner from `getOwnerFarmId()`, with a 10 s retry for slow placeable loads. 418 suite assertions green.
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

## 2026-08-14 (Fred) - open after the DC-17 build

- [ ] **In-game acceptance for DC-17 (a person, with the game running).** The bench
      cannot see these: a mixed-genetics herd shows the AVERAGE in the grade, a
      season of breeding climbs the tier gradually, and the uninstall/reinstall
      cycle announces once and re-announces on the second uninstall (acceptance
      items 1, 2, 4, 5 of the DC-17 brief).
- [ ] **In-game pass owed on DC-8, DC-14, FP-1** (built 2026-08-14, none observed
      in a running game yet).
- [ ] **DC-12's bounded-retry defect still lands.** `RLBridge.safeRead` still
      latches `self.active = false` on the first pcall failure. DC-17 assumed the
      fix; the bridge should retry with a counter and announce once, not latch.
      Also the mode-change event (DC-12 section 3.2) is still log-only.
- [ ] **The DC-11 feed-field designation surface ships callerless** (designed
      state); when FP-1 or a contamination reader wires to it, re-verify the
      placement ruling: the feed-field bonuses currently sit inside the Standard
      score path (`_herdScoreStandard`), so a Ritter farm misses them. Latent
      today, zero callers; fix the placement before the first consumer wires.
- [ ] **`undesignateFeedField` does not mark the barn dirty** while
      `designateFeedField` does, five lines apart. Two-minute fix when someone is
      in that file.
- [ ] **The mod README still carries committed merge-conflict markers** (the
      DC-14/FP-1 PR wave committed them to `development`). Needs its own fix
      branch; not part of any member build.
- [ ] **The farm-business modifier layer for Ritter mode** (mycotoxin, feed-field
      NPK/OM/weed/legume, ProStaff L12 currently only apply in Standard mode).
      This is Defect C of DC-12's fold; DC-17's flag gives a surface the truth to
      show while it is missing.
- [ ] **F12 contract economics:** the per-cow daily yield placeholder (22 L/day)
      is about 15 percent of the SDK's 150 L/day curve; DC-10's volume targets are
      calibrated to the placeholder. Gated on Tyson.
- [ ] **FarmTablet Dairy tab:** the DC-14 read contract currently has no consuming
      app on a client.

