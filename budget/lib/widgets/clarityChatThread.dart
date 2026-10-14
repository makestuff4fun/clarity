import 'package:budget/struct/backend/clarityChat.dart';
import 'package:flutter/material.dart';

/// The agent thread: Brian's messages on the right, Claude's on the left,
/// a kind picker (bug report / change / ask), a text field and a send button.
/// Plain Material widgets, no app globals.
class ClarityChatThread extends StatefulWidget {
  const ClarityChatThread({
    super.key,
    required this.messages,
    required this.onSend,
    this.notice,
  });

  final List<ChatMessage> messages;
  final void Function(String text, String kind) onSend;

  /// Shown above the text field (e.g. "Not paired").
  final String? notice;

  @override
  State<ClarityChatThread> createState() => _ClarityChatThreadState();
}

class _ClarityChatThreadState extends State<ClarityChatThread> {
  final TextEditingController _controller = TextEditingController();
  String _kind = "chat";

  static const Map<String, String> _kinds = {
    "bug": "Bug report",
    "change": "Change",
    "chat": "Ask",
  };

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    widget.onSend(text, _kind);
    _controller.clear();
  }

  Widget _bubble(BuildContext context, ChatMessage m) {
    final scheme = Theme.of(context).colorScheme;
    final mine = m.role == "user";
    final label = mine && m.kind != "chat" ? _kinds[m.kind] : null;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.8),
        child: Card(
          color:
              mine ? scheme.primaryContainer : scheme.surfaceContainerHighest,
          margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment:
                  mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (label != null)
                  Text(label, style: Theme.of(context).textTheme.labelSmall),
                Text(m.text),
                if (m.queued)
                  Row(
                    key: const Key('chat-queued'),
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.schedule, size: 14, color: scheme.outline),
                      const SizedBox(width: 4),
                      Text("Queued",
                          style: Theme.of(context)
                              .textTheme
                              .labelSmall
                              ?.copyWith(color: scheme.outline)),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ms = widget.messages;
    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            reverse: true,
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: ms.length,
            itemBuilder: (context, i) =>
                _bubble(context, ms[ms.length - 1 - i]),
          ),
        ),
        if (widget.notice != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Text(widget.notice!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Wrap(
            spacing: 8,
            children: [
              for (final e in _kinds.entries)
                ChoiceChip(
                  key: Key('chat-kind-${e.key}'),
                  label: Text(e.value),
                  selected: _kind == e.key,
                  onSelected: (_) => setState(() => _kind = e.key),
                ),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('chat-input'),
                    controller: _controller,
                    minLines: 1,
                    maxLines: 5,
                    maxLength: 4000,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      hintText: _kind == "bug"
                          ? "What went wrong?"
                          : _kind == "change"
                              ? "What should change?"
                              : "Ask Claude",
                      counterText: "",
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
                IconButton(
                  key: const Key('chat-send'),
                  icon: const Icon(Icons.send),
                  tooltip: "Send",
                  onPressed: _send,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
