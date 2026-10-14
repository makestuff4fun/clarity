#!/usr/bin/env bash
# Acceptance: clarity/chat-button. PROTECTED. Brian, 2026-10-14: "Since it's a standard for our
# apps, add the agent button to directly add bug reports and queue changes." The fleet standard is
# the course's Chat tab / Rebuild's trainer: the app talks ONLY to its own red server
# (clarity-server's /api/v1/chat/messages, task server-chat), which bridges to a den subject.
#  1. the protected Dart tests (.den/checks/dart/clarity_chat_test.dart + clarity_chat_thread_test.dart,
#     9 tests) pass;
#  2. the app has the button (Key('agent-button')) and a page that uses ClarityChat;
#  3. the app never talks to den or holds a den token: no :8781, no den.token, no /api/v1/chat/<session>;
#  4. flutter build apk --debug succeeds.
source "$(dirname "$0")/flutter_common.sh"
run_dart_tests clarity_chat 9 "$CHK/dart/clarity_chat_test.dart" "$CHK/dart/clarity_chat_thread_test.dart"
L="$B/lib"
btn=$(grep -rln "Key('agent-button')\|Key(\"agent-button\")" "$L" || true)
[ -n "$btn" ] || die "no Key('agent-button') in lib/: the agent button is missing"
users=$(grep -rl 'ClarityChat(' "$L" --include=*.dart | grep -v 'struct/backend/clarityChat.dart' || true)
[ -n "$users" ] || die "nothing in lib/ outside clarityChat.dart constructs ClarityChat: no page uses it"
bad=$(grep -rnE ':8781|den\.token|X-Den-Internal|hanquest\.com:62280/api/v1/chat|lab\.hanquest\.com' "$L" || true)
[ -z "$bad" ] && echo "app talks only to clarity-server" || die "the app must never talk to den directly:
$bad"
rm -rf "$B/build/app/outputs/flutter-apk"
(cd "$B" && flutter build apk --debug >"$T/build.log" 2>&1) || die "flutter build apk --debug failed: $(tail -20 "$T/build.log")"
echo "chat-button OK"
