# AUDAX 0.4.0 — UI revamp (2026-10-24)

Owner (12:18): "I do not like the UI as of now. Change the UI completely, revamp it." Design is
the implementer's **(my call)**; native macOS, SwiftUI, macOS 14+, light and dark.

## Window
One main window, **"AUDAX"**, `NavigationSplitView` with a sidebar (SF Symbols) and a detail
pane. Resizable, minimum 760 × 520, initial 880 × 600, remembers its frame
(`setFrameAutosaveName("AUDAXMain")`). The separate Settings window goes away: ⌘, (menu, Dock
menu, status-item menu) opens this window on **Dictation**.

Toolbar (unified): status capsule (grey "Ready", red "Listening 0:07", orange "Transcribing…")
and a primary button "Start dictation" / "Stop" (calls `toggle()`).

Sidebar sections, in two groups:
- **Dictate**: Home (`house`), History (`clock.arrow.circlepath`)
- **Settings**: Dictation (`keyboard`), AI Provider (`sparkles`), Words (`character.book.closed`)
- About (`info.circle`) at the bottom.

### Home
- Hero card: large app icon or `waveform` glyph, headline "Ready to dictate" / live state,
  sub-line "Hold Fn and speak · Fn Space for hands-free" built from the shortcut displays, the two
  shortcuts drawn as keycaps.
- "Try it here" text box (existing behaviour: a dictation while AUDAX's window is key lands here).
- Setup card, only when something needs attention (microphone, Accessibility, speech engine,
  AI clean-up, Fn tap, Globe key): one row per problem with its fix button; when all is well a
  single green "All set" line.
- Quick controls row: Language (English / Deutsch segmented), Clean-up (Off / Light / Full
  segmented), current provider name with its measured speed hint, linking to AI Provider.
- Last dictation preview with Copy.

### History
- Search field (filters text), list of dictations newest first (from the log, as today; up to 200
  instead of 30). Row: time, text (selectable), Copy, "Copy original" when the clean-up changed
  words, a subtle caption with provider and timings (`stt_s`, `llm_s`) when present.
- Footer: "Open log", count of entries. No delete (owner rule).

### Dictation (settings)
- Shortcuts: Talk and Hands-free recorders drawn as keycap fields, the Globe-key hint card with
  "Open Keyboard settings", the Fn-tap/Accessibility state.
- Sounds toggle, Language, Clean-up level with the one-line explanations.

### AI Provider (settings)  — owned by lane U2
- Provider list as selectable rows with icon, name and a one-line description: Local Ollama,
  GitHub Copilot, Claude API, OpenAI API, Amazon Bedrock, Microsoft Foundry, Other
  (OpenAI-compatible), Other (Anthropic-compatible).
- Detail for the selected provider: model (Copilot: live picker), credentials (Keychain:
  SecureField + Save + Remove), **Advanced** disclosure (base URL, header style, API version;
  Bedrock: region, auth method API key / Access key / AWS profile, profile name), **Test
  connection** with "OK (N ms)" or the error, privacy line (what leaves the Mac), speed hint.
- `.env` banner when `~/.config/audax/.env` sets `AUDAX_PROVIDER` ("Provider and values come from
  ~/.config/audax/.env"), permission warning when the file is group/other-readable, "Open .env
  file" (creates a commented template, mode 0600, only if missing).

### Words
- Two fields + Add, a table of your corrections with a delete button per row (deleting a word
  correction the user created is the user's own action, not data loss by the app), caption about
  built-in corrections.

### About
- Icon, "AUDAX", "Version 0.4.0 (build stamp)" from the bundle, links: Release notes (GitHub
  releases page of zuhussai_adobe/audax), Open log folder, Run setup again.

## Recording pill (HUD)
Floating, non-activating, all spaces, bottom centre, capsule 260 × 46:
- Recording: pulsing red dot, live waveform (24 bars from the meter), mode label "Hold" /
  "Hands-free", elapsed `m:ss`.
- Transcribing: small spinner + "Transcribing…".
- Result: checkmark + "Pasted" (or "Pasted without clean-up", "Copied to the clipboard",
  "Didn't catch that") for 1.2 s.
- Fade + slight scale in/out (0.15 s). Material background (`.hudWindow` visual effect), works on
  light and dark wallpapers. Never takes focus; ignores the mouse; stays visible while AUDAX is
  hidden (0.3.1 behaviour).

## Menu-bar item
Unchanged behaviour; menu: Open AUDAX, Start / stop dictation (shortcut shown), Settings…, Open
log, Quit.

## Constraints
- Keep every existing behaviour and log format; only presentation moves.
- No new dependencies; SwiftUI + AppKit only; `swiftc` via build.sh (add new files to the swiftc
  line).
- Accessibility labels on icon-only buttons.
