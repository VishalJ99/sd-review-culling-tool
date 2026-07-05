# PER-343: Video timestamp UTC/local validation remains unresolved

## Decision

The scanner parses AVFoundation video creation metadata and falls back to file
mtime, but it does not yet validate QuickTime UTC-vs-local interpretation
against adjacent photos from the real card.

## Why

The validation needs a deliberate photo/video pair check and, if needed, a
global offset setting. That logic is separate from the core scanner/export
mechanics implemented in this pass.

## Impact

Chronological ordering can still be wrong if the camera writes QuickTime local
time as UTC and AVFoundation interprets it differently. This should be resolved
before relying on ordering for a full shoot.
