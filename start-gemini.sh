#!/usr/bin/env bash
# Per-repo Antigravity (Gemini) launcher — delegates to the-den's central script.
set -euo pipefail
exec "$HOME/projects/the-den/bin/start-gemini.sh" "$@"
