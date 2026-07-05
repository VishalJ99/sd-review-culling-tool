# SD Card Review & Culling Tool — Implementation Spec

**Version:** 0.3 · **Platform:** native macOS, Swift/AVFoundation (decided) · **Source camera:** Fujifilm X100VI

## 1. Purpose

A keyboard-first desktop tool for rapidly reviewing photos and videos from an SD card in chronological order, keeping or rejecting each item, cropping kept photos, extracting one or more sub-clips from kept videos, and exporting the selected subset to local disk. The output feeds directly into iMovie for a music-driven collage, so the tool optimizes for speed of triage, not editing depth.

Version 1 is **strictly non-destructive**: the SD card is never written to. "Delete" during review means "exclude from export," nothing more. A destructive "apply to source" mode is documented as v2 (§13) but not built now.

## 2. Non-goals (v1)

No RAW editing or conversion, no color grading, no exposure adjustments, no audio/music work, no transitions or titles (iMovie handles all of that), no writing to the SD card, no multi-card merging, no cloud features. Resist scope creep; this is a triage tool.

## 3. Source media facts (Fujifilm X100VI) and their implications

- **Folder layout:** `DCIM/1XX_FUJI/` with files named `DSCF####.JPG`, `DSCF####.RAF`, `DSCF####.MOV`. Numbering wraps at 9999 and spills into new `1XX_FUJI` folders, so **duplicate basenames can exist on one card** — always key items on full relative path, never basename alone.
- **Stills:** 40 MP. JPEGs run roughly 10–25 MB; RAF raw files roughly 45–90 MB. RAFs are ignored for review but see the paired-RAF question in §16. The camera can also be set to save HEIF instead of JPEG — v1 assumes JPEG and should detect and warn if HEIF files are found (§12).
- **Video:** MOV container. Depending on camera settings, either H.264 8-bit 4:2:0 or **H.265/HEVC 10-bit (up to 4:2:2)**, resolutions up to 6.2K/30p, 4K/60p, and 1080/240p, bitrates up to ~200 Mbps. HEVC 10-bit is the reason this is a **native Mac app** (§14): AVFoundation decodes these files directly, whereas browser-based UIs handle them unreliably and would have forced a proxy-transcode pipeline. Still validate playback and scrubbing feel against real 6.2K files from this camera early in development.
- **Card interface:** single UHS-I slot, so cards are typically ≤ ~90 MB/s on read. Fine for playback bandwidth; a full-card ingest of 100 GB would take 20+ minutes, which is why the tool reads from the card in place and only caches previews and poster frames (§10).
- **Timestamps:** for photos, use EXIF `DateTimeOriginal` (+ `SubSecTimeOriginal` for burst ordering). For videos, use the QuickTime creation date. Caveat: the QuickTime spec says UTC, but cameras frequently write local time as if it were UTC. **Validate against a real card** by comparing a video's parsed time to a photo taken seconds apart, and normalize accordingly (exiftool's `QuickTimeUTC` API option handles both interpretations). Never rely on filesystem modification times except as a last-resort fallback.

## 4. Core user flow

1. **Launch → choose source.** Auto-detect mounted volumes containing a `DCIM` folder; also allow picking any folder manually (useful for testing against a copied card).
2. **Choose date range.** Start date via date picker; end date defaults to today. Range is inclusive, based on capture time.
3. **Scan & index.** Fast metadata-only pass builds the timeline; thumbnails and video poster frames generate in the background (§10).
4. **Review loop.** Single-item viewer, strictly chronological (ascending), photos and videos interleaved. Keyboard-driven keep/reject/crop/segment marking (§5–8).
5. **Export.** Renders the kept subset to a local folder with a manifest (§9).

The session autosaves continuously; quitting and relaunching against the same card and date range resumes exactly where the user left off, with all decisions, crops, and segments intact (§11).

## 5. Review model

Every item carries one state: `undecided` (initial), `keep`, or `reject`. Rejecting only flags the item as excluded from export — **the source file is untouched and the item never leaves the timeline**. Rejected items stay visible in the filmstrip with a dimmed/struck treatment, so nothing can silently disappear. Marking keep or reject on an *undecided* item auto-advances to the next one, since fast culling is the whole point; re-flagging an already-decided item does **not** auto-advance (when the user has navigated back to fix something, the view should stay put). Marking a crop or a video segment implicitly sets the item to `keep`.

**Changing your mind — three layers of recovery:**

1. **Undo/redo:** **Cmd+Z / Cmd+Shift+Z**, standard Mac semantics. One unified stack covering decisions, crops, and segment edits (minimum 200 actions), persisted inside the session file so undo survives quit-and-relaunch.
2. **Toggle semantics:** pressing **X** on a rejected item returns it to `undecided`; pressing **K** on a keep does the same. Any item can be re-flagged at any time simply by navigating to it — there is no special "recovery" flow because nothing was destroyed.
3. **Filter views:** **F** cycles All → Undecided → Keeps → Rejects (also a toolbar control). Arrow navigation moves within the active filter. This enables a fast second pass over just the undecided pile, and — the safety net — a final skim of the Rejects view before export to catch anything culled by accident.

Persistent on-screen status: position counter ("137 / 612"), active filter, capture date/time, filename, item state, and a count of remaining undecided items so the user knows when triage is done.

## 6. Photos: viewing and crop

- Fit-to-window display, honoring the EXIF orientation flag.
- **Z** toggles 100% zoom at the cursor position — essential for checking focus/sharpness when culling near-duplicates.
- **C** enters crop mode: a resizable rectangle with aspect presets — keys **1–5** select Free, Original, 16:9, 1:1, 9:16 — plus a rule-of-thirds overlay. Fully keyboard-operable: crop mode captures the arrow keys (arrows move the box, Shift+arrows resize it, Option for fine steps); the mouse can drag the box and its handles as an alternative, never a requirement. Enter confirms, Esc cancels, R clears. (16:9 is the workhorse preset given the iMovie destination.) Crop mode is the **only** place arrows are repurposed — everywhere else they always mean previous/next item.
- Crops are stored non-destructively in the session and applied only at export: bake orientation, apply crop, re-encode JPEG at quality ≥ 92, preserve EXIF (capture date especially), reset the orientation tag. **Uncropped keepers are exported as byte-identical copies** — no needless re-encoding.

## 7. Videos: viewing and splicing (keyboard-first)

Design goal: chop a long clip into its key moments **without touching the mouse**. The mouse stays available — the scrub bar is clickable and segment edges are draggable — but it is never required.

**Moving through a video.** **Space** play/pause; **[ / ]** playback speed down/up (0.5×–2×) for skimming; **Shift+, / Shift+.** jump 1 s back/forward; **, / .** step a single frame for fine positioning. Left/Right arrows are reserved exclusively for previous/next item and never scrub — no mode confusion.

**Marking moments (the core loop).** Watch at 1× or 2× and, *without pausing*, press **I** where a moment starts and **O** where it ends — the pending range highlights live on the scrub bar — then **A** (or Enter) banks it as a segment while playback simply continues. Repeat for the next moment. A three-minute clip with four good moments is: play, I…O A, I…O A, I…O A, I…O A, next item. Marks are order-forgiving (in/out auto-sort; pressing I again just moves the pending in-point), and **Esc** discards a pending mark.

**Editing segments later.** **Tab / Shift+Tab** cycle selection through banked segments — each renders as a colored range on the scrub bar and a row in a list with durations (e.g., "c01 · 0:03.2–0:05.1 · 1.9 s") — and selecting one jumps the playhead to its in-point. While a segment is selected, **I / O re-mark that segment's in/out to the current playhead** (position the playhead with , . or Shift+, . first), and **Delete** removes it. **Esc** deselects, returning I/O to their "new segment" meaning. Every segment operation — add, re-mark, delete — sits on the same Cmd+Z stack as everything else.

- Auto-play on entering a video item; **M** toggles mute. Audio is kept in exported clips even though music will replace it — useful reference during iMovie assembly.
- Segments may overlap; each banked segment becomes an independent output clip at export, and a video with at least one segment is implicitly a keep.
- HEVC 10-bit sources play natively via AVFoundation (§14) — no proxies, no transcoding.

## 8. Keyboard map

Exact letters are at the implementer's discretion; the behaviors are the requirement. Every action below must be reachable without the mouse.

| Key | Action |
|---|---|
| → / ← | Next / previous item within the active filter (never scrubs video) |
| K | Keep an undecided item (auto-advance); on a keep, back to undecided (no advance) |
| X or Delete | Reject an undecided item (auto-advance); on a reject, back to undecided (no advance) |
| Cmd+Z / Cmd+Shift+Z | Undo / redo — decisions, crops, segments alike |
| F | Cycle filter: All → Undecided → Keeps → Rejects |
| Space | Play/pause video |
| [ / ] | Playback speed down / up |
| Shift+, / Shift+. | Jump 1 s back / forward |
| , / . | Frame step back / forward |
| I / O | Mark in / out — re-marks the selected segment's edge if one is selected, otherwise starts/adjusts a new pending segment |
| A or Enter | Bank pending in/out as a segment |
| Tab / Shift+Tab | Select next / previous banked segment |
| Delete (segment selected) | Remove that segment — contextual, since Delete and Backspace share a key on Mac: with a segment selected it removes the segment, otherwise it rejects the item |
| Esc | Deselect segment / discard pending marks / exit mode |
| M | Mute toggle |
| C | Crop mode (photos; captures arrows while active — §6) |
| 1–5 | Aspect preset, crop mode only |
| Z | Toggle 100% zoom (photos) |
| R | Reset crop |
| Cmd+E | Export |
| G | Grid view (v1.1, §15) |

## 9. Export (v1: copy subset to local disk)

Destination defaults to `~/Pictures/SD Review/Export_<YYYY-MM-DD_HHMM>/`, user-changeable. Structure:

```
Export_2026-07-05_1512/
├── photos/
│   └── 20260628_142301_DSCF0123.jpg
├── videos/
│   ├── 20260628_142933_DSCF0124_c01.mov
│   └── 20260628_142933_DSCF0124_c02.mov
└── manifest.json
```

- The `YYYYMMDD_HHMMSS_` prefix comes from capture time, so **alphabetical order equals chronological order** in Finder and on iMovie import. The original camera filename is retained for traceability; `_cNN` numbers a video's segments in time order. Identical timestamp collisions get a `_2` suffix.
- Offer a checkbox for a single flat `media/` folder instead of the photos/videos split, for users who want strict interleaved chronology in one place. Default: split folders.
- **Photo export:** cropped items re-encode per §6; untouched items are straight file copies.
- **Video export — one cut mode in v1 (decided): lossless passthrough with handles.** Trim each segment with `AVAssetExportSession` using the passthrough preset (the AVFoundation equivalent of ffmpeg `-c copy`): no re-encode, near-instant, zero quality loss. Passthrough cuts snap to keyframes, so cut points can shift by up to a GOP (~0.5–1 s); compensate by padding each end with a configurable handle (default 1.0 s, clamped to file bounds). Coarse cuts are explicitly acceptable — the user fine-trims every clip to musical beats in iMovie, so the padding is breathing room, not error. A frame-accurate re-encode mode (VideoToolbox hardware encode) is a possible later addition, deliberately not in v1.
- **`manifest.json`:** complete record of the session outcome — source relative path, file size/hash, decision, crop rectangle, segment times, cut mode, output filenames, tool version. This doubles as the machine-readable input for the future v2 apply-to-source mode.
- **Export dialog as last safety net:** shows the tally (keeps / rejects / undecided) with a one-click jump into the Rejects filter for a final skim before committing. Undecided items are excluded from export just like rejects, so the dialog warns prominently when undecided > 0 ("37 items still undecided — they won't be exported").
- **Pre-flight check:** estimate output size (sum of keeper file sizes plus bitrate × duration for segments) against destination free space; warn or block.
- Export runs in the background with a progress bar; per-file failures are collected and shown at the end rather than aborting the batch. Re-running an export skips files already written and size-verified, so an interrupted export is resumable.
- All card access is read-only throughout the app, enforced at the file-handle level.

## 10. Performance and memory (hard requirements)

A card can easily hold 500–2,000 items at 40 MP and 200 Mbps; naive loading will not survive contact with reality.

- **Two-pass indexing.** Pass 1: metadata-only scan (ImageIO properties for stills, `AVAsset` metadata for video) builds the full timeline fast — target under ~30 s for 1,000 items. Pass 2: background worker generates thumbnails/previews with a priority queue (currently visible and next items first).
- **Photos.** Never hold full 40 MP decodes for browsing. Generate ~2560 px preview JPEGs plus ~320 px filmstrip thumbnails into a disk cache; use the embedded EXIF preview for instant first paint where available. Keep an in-memory LRU of ~6 decoded previews and prefetch ±2 items. Target: < 100 ms photo-to-photo flips once the cache is warm.
- **Videos.** No proxy pipeline — a direct benefit of going native. AVPlayer plays the source files as-is, including HEVC 10-bit. Generate poster frames for the filmstrip during background indexing (`AVAssetImageGenerator`). Validate scrub responsiveness on real 6.2K/200 Mbps files early; if seeking ever feels sluggish on the target machine, an on-demand 720p playback proxy is the contingency — a fallback, not the plan. Cuts always run against the **original** file.
- **Cache.** Location: `~/Library/Caches/<app>/<card-fingerprint>/`, where the fingerprint is derived from volume UUID plus DCIM stats. Size-capped (default 5 GB — it holds only photo previews and poster frames) with LRU eviction, adjustable in settings.
- **Card ejection** mid-session must not crash or corrupt anything: pause gracefully and prompt to reinsert.

## 11. Session persistence

All review state (decisions, crops, segments, last position) lives in a JSON session file in Application Support, keyed by card fingerprint + date range. Autosave on every action (debounced ~500 ms), written crash-safe via temp-file-and-rename. On reopening a matching card/range, offer to resume; provide an explicit "reset session" action. Reviewing hundreds of items rarely happens in one sitting — resume is a core feature, not a nicety.

## 12. Edge cases

- **Duplicate basenames** across `1XX_FUJI` folders (§3): full relative path is the identity.
- **Missing/invalid EXIF:** fall back to file mtime, order the item by that, and show a warning badge.
- **Same-second bursts:** stable secondary sort by sub-second EXIF field, then filename sequence.
- **RAW-only shots** (no JPEG sibling) inside the date range: excluded from review but counted and listed, so shots don't silently vanish. (Assumption: the camera shoots RAW+JPEG.)
- **HEIF stills** if the camera was set to HEIF: out of scope for v1 — detect and surface "N HEIF files found — not supported yet."
- **Corrupt/unreadable files:** skip, collect in a "problems" panel, never crash the review loop.
- **Rotated (portrait) video:** honor rotation metadata in playback and cuts.
- **Suspicious video timestamps** (timezone offset vs. photos, §3): v1 trusts capture metadata after the initial validation; if ordering ever looks wrong, a global "video time offset" setting is the cheap fix (nice-to-have).
- **Zero keepers at export:** block with a clear message.

## 13. v2 (documented only — do not build): apply to source

The stated end goal: once v1 has proven itself reliable, rejects should free up space on the card so culling and shooting can happen in the same loop. Design intent for when that day comes:

- Rejects move to a card-level `.review_trash/` folder or the OS trash — recoverable until explicitly emptied, never an immediate hard delete.
- Deleting a JPEG should default to deleting its paired RAF (behind a clear setting). The RAFs are 3–4× the size of the JPEGs, so leaving them behind defeats the storage-recovery purpose; videos are the biggest wins of all.
- **Trust path:** because the manifest records every reject, v2 can start as a post-export "apply this session's rejects to the card" button — deletion happens only after the export has been inspected and confirmed good. Only after that has proven itself does a "delete as I go" mode (reject trashes immediately, explicit opt-in per session) make sense.
- Trims replacing source videos require per-file re-confirmation and are lower priority than reject-deletion.

This mode needs its own safeguards pass and is out of scope now, but v1's manifest and read-only discipline are designed so it bolts on cleanly.

## 14. Implementation notes — native macOS (decided)

Stack: **Swift/SwiftUI + AVFoundation**, chosen because AVPlayer decodes the camera's HEVC 10-bit files directly, eliminating any proxy/transcode pipeline. A pleasant side effect: no bundled binaries at all — everything below is a system framework.

- **Playback & scrubbing:** `AVPlayer` (via `VideoPlayer` or an `AVPlayerView` wrapper) with a custom transport implementing the keyboard map in §8.
- **Segment cutting:** `AVAssetExportSession` with `AVAssetExportPresetPassthrough` for the lossless padded cuts (§9); audio passes through untouched.
- **Poster frames / filmstrip thumbnails for video:** `AVAssetImageGenerator`.
- **Photo decode, thumbnails, EXIF:** ImageIO — `CGImageSourceCreateThumbnailAtIndex` is fast and uses embedded previews where present; `CGImageSourceCopyPropertiesAtIndex` for `DateTimeOriginal`, sub-second fields, and orientation.
- **Crop + re-encode at export:** Core Graphics/Core Image into an ImageIO destination at quality ≥ 0.92, copying EXIF metadata across.
- **Video timestamps:** `AVAsset` creation date / QuickTime metadata keys, with the UTC-vs-local validation from §3.
- **Keyboard handling:** a local `NSEvent` monitor (or SwiftUI `onKeyPress`) so the §8 map works regardless of which control has focus.

ffmpeg is not required. If some edge case ever exceeds AVFoundation (exotic cut behavior, files from other cameras), bundling ffmpeg later is a contained change. Everything stays local; no network access.

## 15. Milestones

- **M1 — usable immediately:** scan + index, chronological viewer, keep/reject with filters and Cmd+Z undo, export of keeper copies (no crop, no trim). Already a functional culling tool.
- **M2 — video:** AVPlayer playback with the custom keyboard transport, segment marking, passthrough cut export. Still front-loaded because it carries the remaining technical risk (keyframe behavior of passthrough exports, scrub feel on 6.2K files).
- **M3 — photo crop:** crop UI + crop-aware export.
- **M4 — polish:** grid view (**G**) for skimming past boring stretches and bursts, problems panel, flat-export option, settings UI.

## 16. Decisions and remaining assumptions

**Decided:** native macOS app, Swift/AVFoundation (§14). Padded lossless passthrough is the only cut mode in v1 — coarse cuts are acceptable by design (§9). v1 never writes to the card; card-side deletion arrives in v2 once the tool has earned trust through use (§13).

**Still assumed, cheap to change:**

1. Camera saves **JPEG**, not HEIF.
2. Paired RAFs of keepers are **not** copied to the export (toggle-able later if archival copies of the good shots are wanted).
3. One card per session; no merging multiple cards into one timeline.
4. Exported clips **keep their audio** — useful reference during iMovie assembly.