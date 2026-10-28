# Changelog

User-visible changes are recorded here. Pending changes stay in `Unreleased` until a GitHub release is explicitly requested and published.

## Unreleased

## 0.10.0 - 2026-10-28

### Added

- **Answer your AI agents from the notch.** Claude Code questions, plan approvals, and permission requests (in Terminal, an IDE, or the Claude desktop app), Codex questions and permission requests (in Terminal or the Codex app), and questions from NotchMate's own Codex chat appear as cards: step-by-step questions with selectable options and a free-text answer, a formatted plan, or the exact command to approve. Digits pick an answer and Return moves on. A countdown hands the request back to the agent's window if you don't answer, and Codex questions that ask for secrets stay in Codex.
- **One-click updates.** NotchMate checks GitHub once a day and the assistant announces a new version once. About shows what's new; Install and Relaunch downloads the release archive, verifies its checksum, version, and signature, replaces the app, and opens the new version. The menu bar icon offers the same, and you can still download manually or skip a version.
- **Welcome tour** for new users: how to open the panel, the hotkeys, and the plug-in catalog, followed by the permission walkthrough. It can be replayed from About.
- **Join meetings in one click** from the Now strip when a meeting with a call link starts within 10 minutes; the collapsed countdown shows a camera mark for such events.
- **Headphone battery** — left, right, and case, or a single level — appears in the notch when sound switches to Bluetooth headphones such as AirPods, with no extra permission.
- **Weather plug-in** with temperature and conditions in the panel header for the city you choose, and a heads-up from the assistant when rain or snow is likely within two hours. Forecasts come from Open-Meteo, and only the city's coordinates are sent.
- **Share from the shelf** through the system share menu, one file at a time or everything at once.
- **Report a problem** from About with a ready-to-paste report of versions, plug-ins, missing permissions, and recent errors. Your home folder and account name are hidden, and nothing is sent until you paste it.

### Changed

- **A new companion face.** It's drawn live with soft shapes that stay crisp at any size, springs smoothly between moods, blinks and glances around on its own, and plays a short scene for every mood with large animated props — floating hearts, a falling tear, a ball the eyes follow, a fishing float, steaming coffee, and more. It dances to the beat of the music and breathes along with breathing exercises. Blush appears only in affectionate and shy moods. The pixel face is retired.
- Agent sessions in the Now strip show what the agent is waiting for, stay marked as waiting while a question or approval is pending, and open the app the session runs in.
- Installed Claude Code and Codex CLIs are connected automatically on first launch — hooks and the NotchMate MCP server — and existing hooks are updated in place; manual disconnects are respected. Codex and Claude Code bundled with the Codex, ChatGPT, and Claude desktop apps are found even when their command-line tools are not on PATH.
- ← and → switch panel tabs, and VoiceOver reads the panel's buttons, tabs, agent sessions, and request cards.

### Fixed

- Prevent the companion face from crashing when its animation timeline briefly reports a time before the animation started.
- Keep Shelf and Reminders in sync with disk and EventKit when saving fails, prevent a malformed Accessibility value from crashing Git repository detection, and stop Garmin setup cleanly when its helper can't be prepared.

## 0.9.1 - 2026-10-20

### Added

- A plugin catalog in Settings with searchable cards, categories, connection status, configuration, and persistent switches for all built-in modules and integrations, including AI chat, Jira, Git, music, notes, calendar, calls, and health.
- Plugin controls are available only in Settings → Plugin catalog, with no catalog tab or menu-bar item. Disabled modules leave navigation and stop optional background work without deleting accounts, settings, notes, or files. Dependent modules switch off with their parent, and active recordings, AI responses, focus sessions, and unlogged Jira sessions are protected against interruption.
- Call transcripts remain available with AI disabled; completed protocols stay beside the local recording when the Obsidian integration is disabled.
- Configurable one-hour lunch deduction from Jira working time and a breakdown of the counted time for each work-status period.
- Retry failed call processing from the companion's context menu, reusing an existing transcript when available.

### Changed

- Disco is a setting within Music instead of a separate catalog plugin. Disabling it hides the player button and stops both manual and automatic effects; existing disabled preferences are preserved.
- Garmin Connect and Apple Health have independent catalog cards, switches, setup, and synchronization. Their data remains on the shared Health tab; Apple Notes and Obsidian share one Notes tab with an internal source selector.

- Optional background checks and decorative animations pause when the screen is locked or asleep, or the user session is inactive. UI drafts and scroll positions are preserved.
- Low Power Mode and serious thermal pressure reduce polling and animation rates and disable decorative audio capture and disco effects. Active call-recording checks continue.
- Window-coverage checks run every three seconds in normal use, with faster updates during dragging. Notification Center and Dock checks run less frequently.
- System volume and mute controls update through CoreAudio notifications instead of polling, including when the output device changes.
- Live music analysis stops when no enabled visual effect or open music panel needs it. Idle face animations and cursor-following updates run less frequently.
- Clipboard, activity, distraction, companion, Git, and disco polling use adaptive timers with scheduling tolerance; disabled clipboard and disco polling stop when unnecessary.

### Fixed

- Remove the dizzy reaction to rapid cursor movement and bursts of notifications.
- Keep Apple Notes and Obsidian independent: each has its own switch and backend selector within the shared Notes tab, and enabling either no longer changes the selected quick-capture backend or requires the other.
- Restore Apple Notes access when an old preference still points at disabled Obsidian. Surface creation and index errors, support retry after granting Automation access, and preserve recent notes when plaintext is unavailable or a note is created during an index scan.
- Hide AI commit-message controls and their settings hint when the AI plugin is disabled; keep manual commits available and reject generation before reading the diff.
- Prevent a pending audio-capture startup from remaining active after capture is suspended or the playback source changes.
