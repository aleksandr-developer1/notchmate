# Changelog

User-visible changes are recorded here. Pending changes stay in `Unreleased` until a GitHub release is explicitly requested and published.

## Unreleased

### Added

- Configurable one-hour lunch deduction from Jira working time and a breakdown of the counted time for each work-status period.
- Retry failed call processing from the companion's context menu, reusing an existing transcript when available.

### Changed

- Optional background checks and decorative animations pause when the screen is locked or asleep, or the user session is inactive. UI drafts and scroll positions are preserved.
- Low Power Mode and serious thermal pressure reduce polling and animation rates and disable decorative audio capture and disco effects. Active call-recording checks continue.
- Window-coverage checks run every three seconds in normal use, with faster updates during dragging. Notification Center and Dock checks run less frequently.
- System volume and mute controls update through CoreAudio notifications instead of polling, including when the output device changes.
- Live music analysis stops when no enabled visual effect or open music panel needs it. Idle face animations and cursor-following updates run less frequently.
- Clipboard, activity, distraction, companion, Git, and disco polling use adaptive timers with scheduling tolerance; disabled clipboard and disco polling stop when unnecessary.

### Fixed

- Prevent a pending audio-capture startup from remaining active after capture is suspended or the playback source changes.
