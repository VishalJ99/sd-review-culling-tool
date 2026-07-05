# PER-343: Defer detailed export progress UI

## Decision

The exporter now blocks unsafe destinations and insufficient free space, and the
sheet shows estimated output size, but the GUI still uses a single exporting
state rather than a per-file progress bar and final per-file failure panel.

## Why

The first build needed the export pipeline and manifest correctness before
progress instrumentation. The core exporter already returns structured failures
for the GUI to surface later.

## Impact

Long exports have less feedback than the spec requires. Failures are recorded in
`manifest.json` and the sheet's final message, but there is no detailed in-app
failure list yet.
