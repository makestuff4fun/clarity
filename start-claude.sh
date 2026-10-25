#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
exec "$HOME/projects/the-den/bin/claude-start.sh" personal "$@"
