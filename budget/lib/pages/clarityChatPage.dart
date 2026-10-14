import 'dart:async';
import 'dart:io';

import 'package:budget/functions.dart';
import 'package:budget/struct/backend/clarityChat.dart';
import 'package:budget/struct/backend/claritySyncBackend.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/widgets/clarityChatThread.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

const List<String> _kScreenNames = [
  "home",
  "transactions",
  "budgets",
  "more",
  "more",
  "subscriptions",
  "notifications",
  "all-spending",
  "accounts",
  "edit-wallets",
  "edit-budgets",
  "edit-categories",
  "edit-titles",
  "about",
  "goals",
  "edit-goals",
  "upcoming-overdue",
  "credit-debt",
];

/// The name sent as context {"screen"} for a navigation page index.
String clarityScreenName(int page) => page >= 0 && page < _kScreenNames.length
    ? _kScreenNames[page]
    : "page-$page";

/// The fleet's agent button: opens the chat with Claude through clarity-server.
class AgentButton extends StatelessWidget {
  const AgentButton({required this.screen, super.key});

  final String screen;

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton.small(
      key: const Key('agent-button'),
      heroTag: "agent-button",
      tooltip: "Bug report, change or ask",
      onPressed: () => pushRoute(context, ClarityChatPage(screen: screen)),
      child: const Icon(Icons.support_agent),
    );
  }
}

/// Chat with den's "Clarity" subject. Messages queue on disk; while this page
/// is open the queue is flushed and the thread fetched every 2 s.
class ClarityChatPage extends StatefulWidget {
  const ClarityChatPage({required this.screen, super.key});

  final String screen;

  @override
  State<ClarityChatPage> createState() => _ClarityChatPageState();
}

class _ClarityChatPageState extends State<ClarityChatPage> {
  ClarityChat? _chat;
  List<ChatMessage> _messages = [];
  Timer? _timer;
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    final support = await getApplicationSupportDirectory();
    _chat = ClarityChat(
      dir: Directory("${support.path}/clarity_chat"),
      baseUrl: clarityBaseUrl(),
      token: clarityToken,
    );
    await _reload();
    _sync();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _sync());
  }

  Future<void> _reload() async {
    final c = _chat;
    if (c == null) return;
    final ms = await c.messages();
    if (mounted) setState(() => _messages = ms);
  }

  Future<void> _sync() async {
    final c = _chat;
    if (c == null || _syncing || !clarityPaired) return;
    _syncing = true;
    try {
      final sent = await c.flush();
      final got = await c.fetch();
      if (sent > 0 || got.isNotEmpty) await _reload();
    } finally {
      _syncing = false;
    }
  }

  Future<void> _send(String text, String kind) async {
    final c = _chat;
    if (c == null) return;
    await c.send(text, kind: kind, context: {
      "screen": widget.screen,
      "app_version": packageInfoGlobal?.version ?? "",
    });
    await _reload();
    unawaited(_sync());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Claude")),
      body: ClarityChatThread(
        messages: _messages,
        onSend: _send,
        notice: clarityPaired
            ? null
            : "Not paired with clarity-server: messages stay queued until "
                "this device is paired (open a clarity://provision link).",
      ),
    );
  }
}
