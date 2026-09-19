# Changelog

All notable changes to FS25_DairyCore will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Changelog tracking for this mod begins **2026-08-22** under the suite-wide ruling
(see the ecosystem ledger, entry for Arissani and Wizard). Prior history lives in
the repo's git history and README.

---

## [Unreleased]

### Changed
- The office and rota milk sale now charges a fixed handling fee per litre instead of a percentage of the price. The default is 0.011 per litre, set as 11 per 1000 L and tunable from 0 to 50. At the usual milk price that is a smaller cut than the old 5 percent, so most sales pay more than before. A fixed fee is a small share of a dear market and a larger share of a cheap one, which is the point of charging what the handling costs rather than a slice of the sale.
- The admin setting is now **Milk Sale Fee (per 1000 L)**, a whole number from 0 to 50, replacing the old Milk Sale Margin. Existing savegames start at the new default of 11; the old percentage value is not carried over, because a fraction cannot be honestly converted into a rate without knowing the price it was applied at. Set it to 0 to waive the fee entirely.
- The Dairy field guide page 5 now describes the fee, the price source and the refusal.

### Fixed
- A milk sale whose income rounded down to nothing used to remove the milk anyway and pay zero. The sale now works out the price and the fee **before** anything moves, and refuses outright when the fee meets or beats the price: the milk stays in the tank and the barn, no money changes hands, and nothing is recorded as collected. A refused rota round still uses its scheduled slot and the milk keeps ageing normally. The server log carries one line per refusal.
- The milk sale now prices against dynamic pricing only when that pricing is actually running. A disabled, loading, absent or failing price provider falls back to the base price instead of being taken as a real quote, so a price system that is switched off can no longer cause a sale to be refused or underpaid. Dairy contract settlement is unaffected and pays exactly what it paid before.
- `README.md` shipped unresolved merge-conflict markers; both feature descriptions are kept and the markers are gone. The stated admin-settings count was corrected.

### Added
- Translations for the new sale-fee setting and guide text in all 26 supported languages.

## [1.0.0.0] - 2026-09-18

First public release.

### Added
- Changelog file established (suite ruling 2026-08-22).
- Feed-field designation surface (DC-11): a deep dialog opened from the Dairy Esc
  glance ("Feed Fields") lists your owned fields with live soil state and lets you
  toggle each as feed for a barn. This is what makes the feed bonuses and the
  mycotoxin penalty actually fire.
- Harvest contamination now routes into the barn's mycotoxin penalty (DC-11/F105), so a badly stored or spoiled harvest used as feed carries a real consequence.
- Contaminated-feed trough exposure (D1): a herd fed from a contaminated trough accrues exposure, with its own recovery flush path (the C5 hatch) once the trough is cleaned.
- DC-25 milk tank registry: tracks each barn's milk tank as its own tracked record.
- Settlement now gates on a successful payment (F107), so a contract can't be marked settled before the money actually moves.
- Herd health score now counts only active disease records rather than every record ever seen (RSF-F191), in RealisticLivestock (Ritter) mode. Standard mode's herd score does not read disease records at all, so the fix is Ritter-only.

### Fixed
- Barn discovery now distinguishes live milk barns from saved records, and discovers barns through the placeable system directly (DC-32) rather than a weaker lookup. Startup
  retries preserve unresolved dairy state, rebind late-loading barns and notify
  the existing barn and breed surfaces when visibility or ownership changes.
  Diagnostics report live barns and stored records separately.
- Feed-field bonuses and penalties plus the mycotoxin penalty now apply in both
  Standard and RealisticLivestock (Ritter) modes. They previously ran only in the
  Standard score path, so a Ritter-mode farm was silently exempt (DC-11 placement).
- Un-designating a feed field now syncs to co-op partners immediately, matching
  the designation path (F106).

## [1.0.5.4] - 2026-08-22

- First entry under changelog tracking.
