# PER-343: Defer richer mouse scrub and crop-handle affordances

## Decision

The current build is keyboard-first and provides visual crop handles plus video
segment ranges, but it does not yet implement click-to-scrub, draggable video
segment edges, or resize-specific crop handle dragging.

## Why

The spec makes keyboard operation mandatory and mouse operation optional. The
first build focused on validating the keyboard loop against real camera media.

## Impact

This is a UI-completeness gap relative to the wireframes. Mouse users can select
filmstrip items and move the crop box, but cannot yet perform every optional
mouse interaction shown in the references.
