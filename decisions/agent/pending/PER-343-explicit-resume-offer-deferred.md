# PER-343: Auto-resume instead of explicit resume offer

## Decision

When a matching session exists, the app auto-resumes it and shows a visible
"Resumed saved session" status with a Reset button, rather than presenting an
accept/decline prompt before loading the session.

## Why

Auto-resume keeps the keyboard-first flow fast and avoids an extra modal before
review. The follow-up added visible resume state and an explicit reset action,
which gives the user a recovery path if they wanted a fresh session.

## Impact

This is a spec/UX delta. The app preserves session state and allows reset, but
does not strictly implement the requested resume offer.
