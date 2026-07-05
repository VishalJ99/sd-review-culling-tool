# PER-343: Defer preview and thumbnail cache implementation

## Decision

The current app displays full photo files directly in the review pane and uses
icon-style filmstrip tiles instead of the spec's disk-backed preview,
thumbnail, and video poster-frame cache.

## Why

The first usable build prioritized non-destructive source handling, metadata
scan, keyboard culling, crop/segment state, export, and real-camera smoke tests.
The cache is a larger subsystem with eviction, prioritization, and thumbnail
generation workers.

## Impact

This is a performance/spec gap. Large 40 MP photo flips can decode full source
files and will not meet the hard performance target until the preview cache is
implemented.
