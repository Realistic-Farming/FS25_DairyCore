# Changelog

All notable changes to FS25_DairyCore will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Changelog tracking for this mod begins **2026-09-19** under the suite-wide ruling
(see the ecosystem ledger, entry for Arissani and Wizard). Prior history lives in
the repo's git history and README.

---

## [Unreleased]

### Changed
- The office and rota milk sale now charges a fixed handling fee per litre instead of a percentage of the price. The default is 0.011 per litre, set as 11 per 1000 L and tunable from 0 to 50. At the usual milk price that is a smaller cut than the old 5 percent, so most sales pay more than before. A fixed fee is a small share of a dear market and a larger share of a cheap one, which is the point of charging what the handling costs rather than a slice of the sale.
- The admin setting is now **Milk Sale Fee (per 1000 L)**, a whole number from 0 to 50. It replaces the old Milk Sale Margin. Existing savegames start at the new default of 11; the old percentage value is not carried over, because a fraction cannot be honestly converted into a rate without knowing the price it was applied at. Set it to 0 to waive the fee entirely.
- The Dairy field guide page 5 now describes the fee, the price source and the refusal.

### Fixed
- A milk sale whose income rounded down to nothing used to remove the milk anyway and pay zero. The sale now works out the price and the fee **before** anything moves, and refuses outright when the fee meets or beats the price: the milk stays in the tank and the barn, no money changes hands, and nothing is recorded as collected. A refused rota round still uses its scheduled slot and the milk keeps ageing normally. The server log carries one line per refusal.
- The milk sale now prices against dynamic pricing only when that pricing is actually running. A disabled, loading, absent or failing price provider falls back to the base price instead of being taken as a real quote, so a price system that is switched off can no longer cause a sale to be refused or underpaid. Dairy contract settlement is unaffected and pays exactly what it paid before.
- `README.md` shipped unresolved merge-conflict markers; both feature descriptions are kept and the markers are gone. The stated admin-settings count was corrected.

### Added
- Translations for the new sale-fee setting and guide text in all 26 supported languages.
