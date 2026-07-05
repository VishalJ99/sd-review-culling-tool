# PER-343: Corrupt media handling remains incomplete

## Decision

The scanner still does not fully validate and skip every corrupt/unreadable
JPEG or MOV before adding it to the timeline.

## Why

The current scanner handles missing metadata, unsupported HEIF, ignored RAW, and
filesystem enumeration errors well enough for the copied real camera fixture.
Full corrupt-media validation needs deeper ImageIO and AVFoundation load checks
without making scan time too slow.

## Impact

A corrupt file could still enter the review timeline and fail later during
preview, playback, or export. Per-file export failures are collected, but this
does not fully satisfy the spec's scanner-level Problems-panel behavior.
