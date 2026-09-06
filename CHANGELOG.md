# Changelog

All notable changes to FS25_DairyCore will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Changelog tracking for this mod begins **2026-08-22** under the suite-wide ruling
(see the ecosystem ledger, entry for Arissani and Wizard). Prior history lives in
the repo's git history and README.

---

## [Unreleased]

### Fixed
- Dairy barns were not listed on the Farm Tablet or the RF PDA on a fresh mission
  load. The per-frame driver rode an append onto FSBaseMission.update, a hook that
  never fired (no DC-32 retry lines in a near-one-hour session log), so discovery
  ran once before the placeable list was ready and stayed at 0 barns. The driver
  now uses the verified g_currentMission:addUpdateable pattern (same lifecycle as
  TaxMod's updateable): registered on mission load finish, removed on mission
  delete. Discovery retries (DC-32) until barns appear or a 20-attempt cap, and a
  first-pass skip-reason diagnostic (DC-33) logs any milk barn passed over so a
  player log answers "why is my barn not listed" without a debugger. 1.0.5.20.
- 1.0.5.21: the retry is now frame-counted (every ~30 update ticks) instead of
  keyed to wall-time dt, because the shape of an updateable's dt argument is not
  documented in any reference pack and an accumulator could stall at delta 0. The
  per-frame path is pcall-guarded so a hidden construction cannot silently stop
  discovery, and logs a one-time "update loop live" marker plus a per-pass
  "scanned N placeable(s), M dairy barn(s)" line so the next player log proves
  whether discovery sees the placeables.

### Added
- Changelog file established (suite ruling 2026-08-22).
- Feed-field designation surface (DC-11): a deep dialog opened from the Dairy Esc
  glance ("Feed Fields") lists your owned fields with live soil state and lets you
  toggle each as feed for a barn. This is what makes the feed bonuses and the
  mycotoxin penalty actually fire.

### Fixed
- Feed-field bonuses and penalties plus the mycotoxin penalty now apply in both
  Standard and RealisticLivestock (Ritter) modes. They previously ran only in the
  Standard score path, so a Ritter-mode farm was silently exempt (DC-11 placement).
- Un-designating a feed field now syncs to co-op partners immediately, matching
  the designation path (F106).

## [1.0.5.4] - 2026-08-22

- First entry under changelog tracking.
