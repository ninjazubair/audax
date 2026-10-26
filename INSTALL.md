# Installing AUDAX

Hold a key, speak, let go: the text appears where you are typing. About 10 minutes the first time.

## 1. Check your Mac

- Apple Silicon (M1 or later), macOS 14 or newer.
- Homebrew. Check in Terminal with `brew --version`. If it is missing, install it from
  https://brew.sh first.

## 2. Choose how text gets cleaned up

Speech recognition always runs on your Mac and audio never leaves it. The optional clean-up step
fixes punctuation, filler words and grammar. Pick one:

| Option | Disk space | Text leaves the Mac? |
| --- | --- | --- |
| **A. GitHub Copilot** (your existing Copilot seat) | about 0.7 GB | Yes, to GitHub Copilot |
| **B. Off** (raw transcript only) | about 0.6 GB | No |
| **C. Local Ollama** (gemma4 model) | about 11 GB | No |

Claude, OpenAI, Amazon Bedrock, Microsoft Foundry and other gateways also work (0.4.0 and later):
pick them in the app and paste a key. They need about 0.6 GB, like option B.

## 3. Install

Open Terminal and run the block for your option.

**A. GitHub Copilot**

```bash
brew install whisper.cpp gh
gh auth login --hostname github.com --web
```

**B. Off**

```bash
brew install whisper.cpp
```

**C. Local Ollama**: skip this step. The app's setup window installs everything in step 4.

Then:

1. Download the latest DMG from the Releases page, open it and drag **AUDAX** to Applications.
2. The app is self-signed, not notarised by Apple. The first time, **right-click AUDAX → Open →
   Open**. After that it opens normally.

## 4. Get the speech model (547 MB, one time)

**Options A and B.** Do not click "Run setup" in the app: it also installs the 10 GB local model.
Click **Later**, then run this in Terminal:

```bash
SKIP_CLEANUP=1 bash /Applications/AUDAX.app/Contents/Resources/setup.sh
```

**Option C.** Click **Run setup** when AUDAX asks. A Terminal window installs whisper.cpp, the
speech model, Ollama and gemma4. Wait until it says "AUDAX is ready".

If Hugging Face is blocked on your network and you have access to this repository, download the
model from the release instead:

```bash
mkdir -p ~/.cache/mac-dictation/models
gh release download model-whisper-large-v3-turbo-q5_0 -R ninjazubair/audax \
  -p 'ggml-large-v3-turbo-q5_0.bin' -D ~/.cache/mac-dictation/models
shasum -a 256 ~/.cache/mac-dictation/models/ggml-large-v3-turbo-q5_0.bin
# expected: 394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2
```

## 5. Allow permissions

When macOS asks, allow both. If you missed the prompt: System Settings → Privacy & Security.

- **Microphone**: to hear you.
- **Accessibility**: to paste the text and to use the Fn key.

Then System Settings → Keyboard → **"Press 🌐 key to" → Do Nothing**, so macOS does not also react
when you press Fn.

## 6. Pick the clean-up provider in AUDAX

Open AUDAX from the Dock. In 0.4.0 and later this is the **AI Provider** page; in 0.3.x it is in
**Settings**.

- **A. GitHub Copilot**: choose GitHub Copilot. If it says "Not signed in", click **Sign in…**.
  Default model: gpt-6.1-sol.
- **B. Off**: in **Dictation** (0.3.x: Settings), set Clean-up to **Off**.
- **C. Local Ollama**: already the default.

## 7. Use it

| Action | Keys |
| --- | --- |
| Talk | Hold **Fn**, speak, release |
| Hands-free | Hold Fn, tap **Space**, release. Press **Fn Space** again to finish |
| Cancel | Press any other key while holding Fn |

Shortcuts, language (English or German) and your own word corrections are in the app window.

## If something does not work

| Problem | Fix |
| --- | --- |
| "AUDAX can't be opened" | Right-click → Open → Open (step 3). |
| Nothing happens on Fn | Allow Accessibility (step 5), then quit and reopen AUDAX. |
| Text is not pasted | Accessibility is off, or the cursor was not in a text field. |
| "Pasted without clean-up" | The provider failed. Copilot: run `gh auth status` and check the right account is **Active**; AUDAX uses the active account's Copilot seat. Switch with `gh auth switch -u <account>`. |
| App keeps asking for setup | The model is missing: run step 4 again. |
| Need to see what happened | Every dictation is logged in `~/.cache/mac-dictation/dictation.log`. |

## Where AUDAX keeps things

| What | Where |
| --- | --- |
| App | `/Applications/AUDAX.app` |
| Speech model, history log, word corrections | `~/.cache/mac-dictation/` |
| Optional provider file | `~/.config/audax/.env` |
| Settings | macOS defaults domain `local.audax` |
| API keys | Keychain, entries named `local.audax` |

To uninstall, quit AUDAX and remove the items above you no longer want. Then optionally run
`brew uninstall whisper.cpp`; for option C also remove Ollama and its models.
