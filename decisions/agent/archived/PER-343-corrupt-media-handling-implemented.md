# PER-343: Scanner-level corrupt media handling implemented

## Decision

The scanner validates reviewable JPEG and MOV files before adding them to the
timeline. Unreadable JPEG/MOV files are skipped and listed in the Problems
panel. File-attribute read errors are also collected per file rather than
aborting the scan.

## Why

The spec requires corrupt/unreadable files to be skipped, surfaced, and never
allowed to crash the review loop. Scanner-level validation is the right boundary
because preview, playback, and export should not be the first components to
discover an unreadable file.

## Impact

Corrupt files no longer enter the review timeline. The tradeoff is more scanner
work because JPEGs are thumbnail-validated and MOVs must expose a video track
and decode a tiny poster frame during indexing.

## Evidence

`swift test` passed after adding
`MediaScannerTests.testScannerSkipsUnreadableReviewMediaAndReportsProblems`.
The copied-fixture smoke test also passed against real camera MOV/JPG media.
