# PER-343: Implement disk-backed preview cache

## Decision

The app now stores generated JPEG previews, filmstrip thumbnails, and video
poster frames under `~/Library/Caches/SDReview/<card-fingerprint>/`. Photo
review uses the cached preview rather than decoding the full source image for
each display, and filmstrip tiles use cached thumbnails/posters when available.

## Why

The reference spec requires responsive keyboard-first culling on large camera
files. A disk-backed cache reduces repeated source decoding and gives the app a
stable place to reuse generated previews across navigation and relaunches for
the same card fingerprint.

## Impact

Cache generation is best-effort and non-destructive: failure to create a preview
does not modify source media or review state. Cache eviction is size-bounded by
modification-time recency, with the default cap set to 5 GB.

## Evidence

- `swift test`
- `SDREVIEW_FIXTURE="/Users/vishaljain/Documents/Video editor/.local-test-data/sd-last-24h-20260705-1748" swift test --filter FixtureSmokeTests`
