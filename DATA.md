# DATA.md

One-line manifest for data and persistent non-source artifacts.

- `.local-test-data/` — Gitignored local test fixtures and smoke-test exports; each fixture/export directory must include its own `reproduction.txt`.
- `.local-test-data/sd-last-24h-20260705-1748/` — Local copied fixture from `/Volumes/Untitled/DCIM`, 477 files, 29,698,155,690 bytes, created for PER-343 app testing; see its `reproduction.txt` and `copy_manifest.json`.
- `.local-test-data/smoke-export-core/` — Local smoke-test export from the copied fixture, 29 MB, with one real JPG copy, one real MOV passthrough segment, `manifest.json`, and `reproduction.txt`.
- `docs/spec/sd-review-implementation-spec.md` — Committed copy of the implementation spec used for this build.
- `docs/wireframes/` — Committed copies of the provided SVG wireframes used as UI references.
