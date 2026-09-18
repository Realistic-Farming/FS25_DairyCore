# Changelog

All notable changes to FS25_DairyCore will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Changelog tracking for this mod begins **2026-08-22** under the suite-wide ruling
(see the ecosystem ledger, entry for Arissani and Wizard). Prior history lives in
the repo's git history and README.

---

## [Unreleased]

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
- Herd health score now counts only active disease records rather than every record ever seen (RSF-F191), fixed in both Standard and RealisticLivestock (Ritter) modes.

### Fixed
- Barn discovery now distinguishes live milk barns from saved records, and discovers barns through the placeable system directly (DC-32) rather than a weaker lookup. Startup
  retries preserve unresolved dairy state, rebind late-loading barns and notify
  the existing barn and breed surfaces when visibility or ownership changes.
  Diagnostics report live barns and stored records separately. Test package
  version 1.0.5.24 distinguishes this correction from the earlier retry diagnostics.
- Feed-field bonuses and penalties plus the mycotoxin penalty now apply in both
  Standard and RealisticLivestock (Ritter) modes. They previously ran only in the
  Standard score path, so a Ritter-mode farm was silently exempt (DC-11 placement).
- Un-designating a feed field now syncs to co-op partners immediately, matching
  the designation path (F106).

## [1.0.5.4] - 2026-08-22

- First entry under changelog tracking.
