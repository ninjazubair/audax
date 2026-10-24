# AUDAX v3 — addendum to the v2 design (2026-10-24)

Owner feedback after trying 0.2.1 (09:18–09:20, three dictations logged, all pasted into the
AUDAX window): the Fn key could not be set as a shortcut; Copilot should default to `gpt-6.1-sol`
and let the user pick from the models the seat offers; no audible start sound; it should be
faster. Decisions below are the implementer's **(my call)** unless marked owner.

## Measured 2026-10-24 (sources: `~/.cache/mac-dictation/dictation.log`; live calls on the
owner's Copilot Business seat; `/opt/homebrew/bin/whisper-server`)
- Three real dictations: STT 0.42–0.49 s, Copilot `gpt-4.1` clean-up 1.85–2.56 s. Copilot is the
  slow step; local gemma4 does it in 0.3–0.7 s.
- `GET {host}/models` returns 38 models; `gpt-6.1-sol` (and all current OpenAI models) support
  only `/responses`; `gpt-4.1` has `model_picker_enabled: false`, `supported_endpoints: []` but
  works on `/chat/completions`.
- One `gpt-6.1-sol` `/responses` call: HTTP 200, correct clean-up, **4.64 s** (n=1).
- Audio output healthy (`say` completes; coreaudiod up). The 0.2.1 start tick is 880 Hz, 0.09 s,
  amplitude 0.28 — too faint to notice.
- Nothing was stored for the shortcuts: `Shortcut.from` requires ⌃ or ⌥ and only sees `keyDown`;
  Fn alone produces `flagsChanged` only, and Carbon `RegisterEventHotKey` has no Fn modifier.

## Decisions

### Fn shortcuts (owner)
- Defaults become **hold Fn = talk**, **Fn+Space = hands-free**. Both recordable in Settings
  exactly like other keys: pressing Fn alone records "Fn"; Fn+key records "Fn+<key>".
- Engine **(my call)**: shortcuts that involve Fn (or are modifier-only) are handled by a
  session-level `CGEvent` tap (`flagsChanged` for Fn press/release via keyCode 63; `keyDown` /
  `keyUp` for Fn+key, swallowed so the key is not typed). Non-Fn shortcuts keep Carbon hot keys.
  The tap needs Accessibility, which AUDAX already requires for pasting; if it is not granted, the
  check row says so and the Carbon path still works for non-Fn shortcuts.
- Modifier rule becomes: at least one of ⌃, ⌥, **Fn** (⇧-only and ⌘-only still rejected).
- macOS runs its own Globe-key action on an Fn tap (emoji picker / input source / dictation)
  unless System Settings → Keyboard → "Press 🌐 key to" is **Do Nothing**. The app reads
  `com.apple.HIToolbox AppleFnUsageType`; when the talk key is Fn and the value is not 0, the
  Settings Recording box and the check row show "macOS also uses the Fn key: set 'Press 🌐 key
  to' to Do Nothing" with a button that opens the Keyboard pane. The app never changes system
  settings itself. Whether a tap can suppress that system action is unknown; not attempted.

### Copilot models (owner: default `gpt-6.1-sol`; picker if possible)
- `providers.copilot_models(token, host)` = `GET {host}/models`, keep entries with
  `model_picker_enabled` or id `gpt-4.1`; route = `/chat/completions` if listed or if
  `supported_endpoints` is empty, else `/responses` if listed, else dropped. Cached 10 min in
  `~/.cache/mac-dictation/copilot_models.json` (ids, names, routes only; no token).
- `/responses` request **(my call)**: `{"model", "instructions": system, "input": [{"role":
  "user", "content": [{"type": "input_text", "text": user}]}], "store": false}`; text = join of
  `output[].content[].text` where `output[].type == "message"` and `content[].type == "output_text"`.
- Settings shows a Picker of the live list (fetched by Swift through `python3 providers.py
  --copilot-models`, printed as JSON) with the saved id kept if absent; caption with the measured
  timings: "Measured on the developer's Mac: local gemma4 ≈0.3 s, gpt-4.1 ≈2 s, gpt-6.1-sol
  ≈2.7–4.9 s per dictation."

### Start sound (owner: no beep heard)
- Start = the v1 rising two-note (659.3 → 987.8 Hz, length 0.22) at amplitude 0.35; pasted and
  nothing-heard sounds unchanged. When `AVAudioEngine` fails to start, log one line
  `{"warning": "audio engine did not start"}` (silent otherwise).

### Speed (owner)
- Resident speech-to-text **(my call)**: the app launches `whisper-server` (`/opt/homebrew/bin`,
  `--host 127.0.0.1 --port 18777 -m <model>`) at start and keeps it alive (restart on exit, at
  most once a minute); `dictate.py` POSTs the WAV to `http://127.0.0.1:18777/inference`
  (multipart, `temperature=0`, `response_format=json`, `-l` as `language`, prompt vocabulary as
  `prompt`) and falls back to `whisper-cli` when the server is not reachable. **Gate**: Task 10
  measures both paths on the same clip first; the server path ships only if it saves ≥ 0.15 s per
  dictation, otherwise the task records the numbers and stops.
- The honest speed message to the owner: with Copilot `gpt-6.1-sol` a dictation takes ≈5 s of
  which ≈4.6 s is the model; local gemma4 brings the whole thing to ≈1 s.

## Non-goals
Suppressing macOS's Globe-key action; streaming transcription; a Windows build.

## Constraints
As v2 (Python 3.9 stdlib; swiftc, MIN_MACOS 14.0; secrets never in logs/env/argv/files; no file
deletion; smoke runs with `AUDAX_NO_PASTE=1 CFFIXED_USER_HOME=<scratch> HOME=<scratch>` and
0.15 s SIGUSR1 pairs; relaunch `/Applications/AUDAX.app` right after any smoke).
