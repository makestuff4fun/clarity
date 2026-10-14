// Acceptance: clarity/chat-button, the screen half. PROTECTED (.den/**). The pinned widget
// ClarityChatThread (lib/widgets/clarityChatThread.dart): plain Material widgets, no app globals.
import 'package:budget/struct/backend/clarityChat.dart';
import 'package:budget/widgets/clarityChatThread.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ChatMessage msg(int id, String role, String text, {String kind = 'chat', String? state}) =>
    ChatMessage(id: id, role: role, text: text, kind: kind, clientId: 'c$id', state: state);

Widget host(List<ChatMessage> ms, void Function(String, String) onSend) =>
    MaterialApp(home: Scaffold(body: ClarityChatThread(messages: ms, onSend: onSend)));

void main() {
  testWidgets('shows the thread; a queued message is marked', (t) async {
    await t.pumpWidget(host([
      msg(1, 'user', 'Total is wrong', kind: 'bug', state: 'sent'),
      msg(2, 'agent', 'Queued clarity/fix-total.'),
      msg(-1, 'user', 'Add CSV export', kind: 'change', state: 'queued'),
    ], (_, __) {}));
    await t.pumpAndSettle();
    expect(find.text('Total is wrong'), findsOneWidget);
    expect(find.text('Queued clarity/fix-total.'), findsOneWidget);
    expect(find.text('Add CSV export'), findsOneWidget);
    expect(find.byKey(const Key('chat-queued')), findsOneWidget);
  });

  testWidgets('pick "bug report", type, send: onSend(text, "bug") and the field clears', (t) async {
    final sent = <List<String>>[];
    await t.pumpWidget(host([], (text, kind) => sent.add([text, kind])));
    await t.tap(find.byKey(const Key('chat-kind-bug')));
    await t.pump();
    await t.enterText(find.byKey(const Key('chat-input')), 'Crash on Budgets tab');
    await t.tap(find.byKey(const Key('chat-send')));
    await t.pump();
    expect(sent, [
      ['Crash on Budgets tab', 'bug']
    ]);
    expect(find.text('Crash on Budgets tab'), findsNothing);
  });

  testWidgets('"queue a change" sends kind change; empty text sends nothing', (t) async {
    final sent = <List<String>>[];
    await t.pumpWidget(host([], (text, kind) => sent.add([text, kind])));
    await t.tap(find.byKey(const Key('chat-send')));
    await t.pump();
    expect(sent, isEmpty);
    await t.tap(find.byKey(const Key('chat-kind-change')));
    await t.pump();
    await t.enterText(find.byKey(const Key('chat-input')), 'Monthly CSV export');
    await t.tap(find.byKey(const Key('chat-send')));
    await t.pump();
    expect(sent, [
      ['Monthly CSV export', 'change']
    ]);
    expect(find.byKey(const Key('chat-kind-chat')), findsOneWidget);
  });
}
