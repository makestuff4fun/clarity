import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The body of the "Pair with red" screen, in plain Material so it can be
/// tested on its own: a camera button, and a field that takes the bare
/// one-time code or a full clarity:// link, with one-tap paste.
class ClarityPairForm extends StatefulWidget {
  const ClarityPairForm({
    super.key,
    required this.onScan,
    required this.onSubmit,
  });

  /// The camera button was tapped.
  final VoidCallback onScan;

  /// The typed or pasted text, as entered.
  final void Function(String text) onSubmit;

  static const Key scanButtonKey = Key("clarity-pair-scan");
  static const Key fieldKey = Key("clarity-pair-field");
  static const Key pasteButtonKey = Key("clarity-pair-paste");
  static const Key pairButtonKey = Key("clarity-pair-submit");

  @override
  State<ClarityPairForm> createState() => _ClarityPairFormState();
}

class _ClarityPairFormState extends State<ClarityPairForm> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
    final String text = data?.text?.trim() ?? "";
    if (text.isEmpty) return;
    setState(() => _controller.text = text);
    widget.onSubmit(text);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            "Pair this phone with red: scan the pairing QR code shown on a screen, "
            "or type or paste the one-time code or the clarity:// link.",
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            key: ClarityPairForm.scanButtonKey,
            onPressed: widget.onScan,
            icon: const Icon(Icons.qr_code_scanner_rounded),
            label: const Text("Scan QR code"),
          ),
          const SizedBox(height: 24),
          TextField(
            key: ClarityPairForm.fieldKey,
            controller: _controller,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.done,
            onSubmitted: widget.onSubmit,
            decoration: InputDecoration(
              labelText: "Pairing code or clarity:// link",
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                key: ClarityPairForm.pasteButtonKey,
                tooltip: "Paste and pair",
                icon: const Icon(Icons.content_paste_rounded),
                onPressed: _paste,
              ),
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            key: ClarityPairForm.pairButtonKey,
            onPressed: () => widget.onSubmit(_controller.text),
            child: const Text("Pair"),
          ),
        ],
      ),
    );
  }
}
