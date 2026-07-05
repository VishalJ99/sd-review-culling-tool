# PER-343: Use filesystem mtime for the safety-copy window

## Decision

The local SD-card test fixture was selected by filesystem modification time in
the last 24 hours, not by EXIF/QuickTime capture metadata.

## Why

`exiftool` is not installed on this machine, and this copy step is only a safety
guard before app testing. The application implementation still uses
ImageIO/AVFoundation metadata for review ordering, as required by the spec.

## Impact

The copied fixture might differ from a strict capture-time-last-24-hours set if
card mtimes diverge from capture times. The manifest records every copied file
and the fixture is local-only, so the test can be regenerated with a different
windowing rule if needed.
