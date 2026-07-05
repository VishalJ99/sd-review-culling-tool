# AGENTS.md

## Project Purpose

Build a native macOS SD-card review and culling tool for Fujifilm X100VI media.
The app is keyboard-first, non-destructive in v1, and optimized for fast review,
photo crop, video segmenting, and export into iMovie.

Primary tracking issue: PER-343.
Linear project: SD Review & Culling Tool.

## Current Spec Inputs

- Implementation spec: `docs/spec/sd-review-implementation-spec.md`
- Wireframes: `docs/wireframes/`

The original pasted spec and SVGs are source inputs. Consequential deviations
from the spec must be recorded in `decisions/agent/pending/` for user review.

## Build And Test

- Build: `swift build`
- Test: `swift test`
- Run app from source: `swift run SDReview`

Use Xcode 26+ on macOS. The app target is Swift/SwiftUI with AVFoundation and
ImageIO/CoreGraphics for media handling.

## Data Safety

Version 1 must never write to source SD-card media. Testing against camera data
must use a copied local fixture under `.local-test-data/`, which is gitignored.
Every copied fixture directory must contain:

- `reproduction.txt`
- `copy_manifest.json`

Export smoke-test outputs also stay under `.local-test-data/` unless the user
explicitly asks for a durable exported bundle elsewhere.

## Decisions

Agent-made consequential decisions go to:

- `decisions/agent/pending/`

Keep entries short and reviewable. Promote, archive, consolidate, or discard
them during closeout.

## Logbook

Use `logbook/YYYY-MM.md` for observational work such as real-card validation,
timestamp checks, export smoke tests, and review-agent findings. Pure code edits
do not need logbook narration.
