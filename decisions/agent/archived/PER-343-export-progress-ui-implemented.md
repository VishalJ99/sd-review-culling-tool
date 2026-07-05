# PER-343: Implement export progress and failure UI

## Decision

The exporter now emits progress callbacks with completed item count, total item
count, current relative path, and collected failures. The export sheet displays
a progress bar, current path, and per-file failures, and it can jump directly to
the Rejects filter in grid mode for the final safety skim.

## Why

The spec makes the export dialog the last safety net before writing outputs.
Progress and failure visibility are required for long exports and for resumable
retry behavior to be understandable.

## Impact

Per-file failures still do not abort the batch. They are collected in the GUI
and in `manifest.json`, so a user can inspect failures and rerun the export.
The manifest records output sizes and SHA-256 hashes; reruns verify existing
outputs before skipping, and new or replacement outputs are written through temp
files before replacing final paths.

## Evidence

- `swift test`
- `SDREVIEW_FIXTURE="/Users/vishaljain/Documents/Video editor/.local-test-data/sd-last-24h-20260705-1748" swift test --filter FixtureSmokeTests`
