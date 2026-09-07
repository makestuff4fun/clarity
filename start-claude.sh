#!/usr/bin/env bash
# Launch Claude Code for this project.
#
# The ACCOUNT POLICY is not here on purpose -- it lives in one place,
# ~/projects/the-den/bin/claude-start.sh, so it cannot drift across the ~40
# copies of this file. Fix it there, not here.
#   personal -> best of slots 2/3 (bbarr095 / jtombarrett) by remaining headroom
#   work     -> slot 1 (brian@humanarchive.ai, the work Team seat)
#
# The old "red does NOT use cswap" comment was true until 2026-09-06 and is not
# any more: red carries slots 2 and 3 (the work seat was removed by design).
# The abandoned resume/AGENT_RESUME and shutdown/dirty contracts are gone too --
# sessions start normally now.
set -euo pipefail
cd "$(dirname "$0")"

exec "$HOME/projects/the-den/bin/claude-start.sh" personal "$@"
