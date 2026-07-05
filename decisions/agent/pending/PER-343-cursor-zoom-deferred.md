# PER-343: Defer true cursor-anchored 100% zoom

## Decision

The app still implements photo zoom as a centered preview-scale toggle instead
of the spec's exact 100% zoom anchored at the cursor.

## Why

The review-agent follow-up prioritized correctness and safety blockers:
source-safe fixture refresh, export resumability, crash-safe session writes,
visible reset/resume controls, crop/export coordinate correctness, source
availability warning, original aspect, and source-frame stepping. True 100%
cursor zoom requires a more specialized image viewport with pixel-to-screen
mapping and is not needed for the non-destructive cull/export workflow to be
safe.

## Impact

This is a UI fidelity gap for inspecting critical focus at native resolution.
Users can still toggle a larger centered preview, but not exact cursor-anchored
1:1 inspection.
