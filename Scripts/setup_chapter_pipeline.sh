#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIPELINE_DIR="$ROOT_DIR/ChapterPipeline"
VENV_DIR="$PIPELINE_DIR/.venv"
DEFAULT_MODEL="${M4B_FORGE_OLLAMA_MODEL:-qwen3.5:9b}"

log() {
  printf '[M4B Forge Pipeline] %s\n' "$1"
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log "Missing required command: $1"
    return 1
  fi
}

if ! command -v brew >/dev/null 2>&1; then
  log "Homebrew is required for this setup script."
  log "Install it from https://brew.sh, then rerun this script."
  exit 1
fi

if ! command -v ollama >/dev/null 2>&1; then
  log "Installing Ollama with Homebrew."
  brew install ollama
else
  log "Ollama already installed."
fi

require_command python3

if [ ! -d "$VENV_DIR" ]; then
  log "Creating Python virtual environment at $VENV_DIR."
  python3 -m venv "$VENV_DIR"
else
  log "Python virtual environment already exists."
fi

# shellcheck source=/dev/null
source "$VENV_DIR/bin/activate"

log "Upgrading pip."
python3 -m pip install --upgrade pip

log "Installing local transcription dependencies."
python3 -m pip install --upgrade mlx-whisper

if ! pgrep -x ollama >/dev/null 2>&1; then
  log "Starting Ollama in the background for model install."
  ollama serve >/tmp/m4b-forge-ollama.log 2>&1 &
  sleep 3
fi

log "Pulling Ollama model: $DEFAULT_MODEL"
ollama pull "$DEFAULT_MODEL"

log "Setup complete."
log "Activate with: source ChapterPipeline/.venv/bin/activate"
log "Read: ChapterPipeline/README.md"
