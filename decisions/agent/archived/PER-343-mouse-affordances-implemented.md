# PER-343: Implement optional mouse scrub and crop affordances

## Decision

The app remains keyboard-first, but now supports optional mouse interaction for
video scrub seeking, video segment edge dragging, crop-box body dragging, and
crop handle resizing.

## Why

Keyboard operation is the primary requirement, but the wireframes include mouse
affordances for users who want to skim or adjust visually. Adding these controls
does not change the keyboard map.

## Impact

Segment edge drags update the stored segment when the drag ends, while the
playhead follows during the drag. This avoids committing many undo entries for a
single mouse adjustment.

## Evidence

- `swift test`
- `SDREVIEW_FIXTURE="/Users/vishaljain/Documents/Video editor/.local-test-data/sd-last-24h-20260705-1748" swift test --filter FixtureSmokeTests`
