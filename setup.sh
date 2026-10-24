#!/bin/bash
# AUDAX first-run setup: the local speech engine, its model, and the local clean-up model.
# Bundled inside AUDAX.app and opened in Terminal by the app when something is missing.
# Safe to re-run: skips what is already there. No Docker, nothing sent to the cloud.
set -euo pipefail

MODEL_DIR="$HOME/.cache/mac-dictation/models"
MODEL="ggml-large-v3-turbo-q5_0.bin"   # 574 MB, runs on the Apple GPU
OLLAMA_MODEL="gemma4"                    # local clean-up; check AI Radar before rollout

echo "== AUDAX setup =="
[ "$(uname -m)" = "arm64" ] || { echo "AUDAX needs an Apple Silicon Mac."; exit 1; }
if ! command -v brew >/dev/null && [ ! -x /opt/homebrew/bin/brew ]; then
  echo "Homebrew is needed first. Opening https://brew.sh - install it, then run AUDAX again."
  open https://brew.sh
  exit 1
fi
export PATH="/opt/homebrew/bin:$PATH"

echo "-- Speech engine (whisper.cpp)"
brew list whisper.cpp >/dev/null 2>&1 || brew install whisper.cpp

echo "-- Speech model (574 MB, one-time download)"
mkdir -p "$MODEL_DIR"
if [ ! -s "$MODEL_DIR/$MODEL" ]; then
  curl -fL --progress-bar -o "$MODEL_DIR/$MODEL.part" \
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$MODEL"
  mv "$MODEL_DIR/$MODEL.part" "$MODEL_DIR/$MODEL"
fi

if [ "${SKIP_CLEANUP:-0}" != "1" ]; then
  echo "-- Clean-up model (Ollama + $OLLAMA_MODEL)"
  [ -d /Applications/Ollama.app ] || brew install --cask ollama-app
  OLLAMA=/Applications/Ollama.app/Contents/Resources/ollama  # the CLI may not be on PATH yet
  curl -sf localhost:11434/api/tags >/dev/null || open -a Ollama
  for _ in $(seq 60); do curl -sf localhost:11434/api/tags >/dev/null && break; sleep 1; done
  "$OLLAMA" list 2>/dev/null | grep -q "^$OLLAMA_MODEL" || "$OLLAMA" pull "$OLLAMA_MODEL" ||
    echo "Clean-up model not installed: dictation still works, without the clean-up step."
fi

echo
echo "AUDAX is ready. Close this window, then hold Fn in any text field, speak, and let go."
echo "Tip: set System Settings > Keyboard > 'Press 🌐 key to' to Do Nothing so macOS does "\
"not also react to Fn."
