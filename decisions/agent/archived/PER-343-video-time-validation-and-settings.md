# PER-343: Add video timestamp validation and timing settings

## Decision

Video capture dates can be shifted by a persisted global video-time offset in
Settings. The scanner also warns when a video timestamp differs from a nearby
camera-numbered photo by approximately the local time-zone offset.

## Why

The spec calls out QuickTime UTC-vs-local ambiguity as the main ordering risk.
A global offset is the lowest-cost correction, and warning on likely
timezone-sized deltas makes the issue visible without blocking review.

## Impact

The validator is heuristic: it depends on nearby Fuji sequence numbers and a
timezone-sized delta. It avoids rewriting metadata and only affects in-app
ordering on the next scan when a user sets an offset.

## Evidence

- `swift test`
- `SDREVIEW_FIXTURE="/Users/vishaljain/Documents/Video editor/.local-test-data/sd-last-24h-20260705-1748" swift test --filter FixtureSmokeTests`
