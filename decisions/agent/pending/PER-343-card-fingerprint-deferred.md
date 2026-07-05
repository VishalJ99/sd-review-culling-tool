# PER-343: Use source path and date range for session identity for now

## Decision

Session files are keyed by source root path plus date range, not by the spec's
volume-UUID-plus-DCIM-stats card fingerprint.

## Why

Path/date identity was sufficient to validate resume behavior against the copied
fixture. A robust card fingerprint needs volume metadata and DCIM stat handling
that should be implemented together with the preview cache path layout.

## Impact

Renaming/remounting a card or moving a copied fixture can prevent automatic
resume. Different cards copied to the same path and date range could collide.
