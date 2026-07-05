# PER-343: Explicit resume offer implemented

## Decision

When a matching saved session exists for the scanned card/date range, the app
now presents a resume offer instead of auto-loading the session immediately.
The user can resume, start fresh, or cancel.

## Why

The spec calls resume a core feature and explicitly requires an offer to resume
on reopening a matching card/range. The previous auto-resume plus reset control
was recoverable, but it skipped that choice point.

## Impact

Users now make the resume/fresh decision before entering review. Starting fresh
clears matching saved session files and persists the new clean session so the
old state is not silently offered again.

## Evidence

`swift test` passed after the scan/resume state change and SwiftUI sheet build.
