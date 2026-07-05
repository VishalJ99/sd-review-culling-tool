# PER-343: Cursor-anchored cached-preview zoom implemented

## Decision

Photo zoom now anchors at the cursor position and scales the cached preview
toward 1:1 preview pixels, capped to avoid extreme overscaling.

## Why

The spec requires zoom at the cursor for focus/sharpness checks, while the
performance section also says not to hold full 40 MP decodes for browsing and
to use cached preview JPEGs. A cursor-anchored 1:1 cached-preview zoom satisfies
the interaction requirement without violating the preview-cache architecture.

## Impact

The implementation is more faithful than the previous centered 1.9x toggle.
It is not a full-resolution 40 MP loupe; if real use shows the cached preview is
insufficient for near-duplicate focus checks, the next change should add an
on-demand full-resolution loupe for the current photo only.

## Evidence

`swift test` passed after the SwiftUI hover-anchor and zoom-scale build.
