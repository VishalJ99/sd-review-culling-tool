# PER-343: Use card fingerprint for session identity

## Decision

Session files are keyed by a card fingerprint plus date range when a scan
provides one. The fingerprint is a SHA-256 digest derived from volume UUID,
scan-root path, media folder names, media file count, total media bytes, and the
latest media modification time.

## Why

The spec calls for session identity that survives ordinary app relaunches and is
less fragile than path-only matching. The copied fixture and mounted card flows
both provide enough filesystem metadata to derive a stable identity without
writing to the source.

## Impact

Moving a copied fixture to a different path still changes the fingerprint
because the root path remains part of the digest. This avoids accidental
collisions between unrelated local copies at the cost of not treating moved
fixtures as the same card. The path component can be removed later if the user
wants resume behavior to follow moved copies.

## Evidence

- `swift test`
- `SDREVIEW_FIXTURE="/Users/vishaljain/Documents/Video editor/.local-test-data/sd-last-24h-20260705-1748" swift test --filter FixtureSmokeTests`
