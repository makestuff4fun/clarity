import 'package:budget/functions.dart';
import 'package:budget/struct/clarityPairInput.dart';
import 'package:budget/widgets/clarityPairForm.dart';
import 'package:budget/widgets/clarityProvision.dart';
import 'package:budget/widgets/framework/pageFramework.dart';
import 'package:budget/widgets/globalSnackbar.dart';
import 'package:budget/widgets/openSnackbar.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// "Pair with red": scan the pairing QR, or type/paste the code or link.
/// Every way in ends in [redeemProvisionLink], the path a
/// clarity://provision link takes, so success and failure read the same.
class ClarityPairPage extends StatelessWidget {
  const ClarityPairPage({super.key});

  static void _refuse(PairRefusal r) {
    openSnackbar(SnackbarMessage(
      title: r.title,
      description: r.description,
      icon: Icons.link_off_rounded,
    ));
  }

  Future<void> _scan(BuildContext context) async {
    // The camera permission is asked for here, when the scanner starts.
    final String? raw = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const ClarityPairScanner()),
    );
    if (raw == null) return;
    await pairFromInput(raw,
        source: PairSource.scanned,
        redeem: redeemProvisionLink,
        refuse: _refuse);
  }

  @override
  Widget build(BuildContext context) {
    return PageFramework(
      title: "Pair with red",
      dragDownToDismiss: true,
      listWidgets: [
        ClarityPairForm(
          onScan: () => _scan(context),
          onSubmit: (text) => pairFromInput(text,
              source: PairSource.typed,
              redeem: redeemProvisionLink,
              refuse: _refuse),
        ),
      ],
    );
  }
}

Future<void> openClarityPairPage(BuildContext context) =>
    pushRoute(context, const ClarityPairPage());

/// Full-screen camera that returns the first QR code's text (or null).
class ClarityPairScanner extends StatefulWidget {
  const ClarityPairScanner({super.key});

  @override
  State<ClarityPairScanner> createState() => _ClarityPairScannerState();
}

class _ClarityPairScannerState extends State<ClarityPairScanner> {
  final MobileScannerController _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final Barcode b in capture.barcodes) {
      final String? raw = b.rawValue;
      if (raw != null && raw.isNotEmpty) {
        _done = true;
        Navigator.of(context).pop(raw);
        return;
      }
    }
  }

  Widget _error(BuildContext context, MobileScannerException e) {
    final bool denied =
        e.errorCode == MobileScannerErrorCode.permissionDenied;
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.all(24),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(denied ? Icons.no_photography_rounded : Icons.error_rounded,
              color: Colors.white, size: 48),
          const SizedBox(height: 16),
          Text(
            denied ? "Camera permission denied" : "The camera did not start",
            style: const TextStyle(color: Colors.white, fontSize: 20),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            denied
                ? "Clarity needs the camera only to scan the pairing QR code. "
                    "Allow it in Android settings, or go back and type the code instead."
                : "Go back and type or paste the pairing code instead.",
            style: const TextStyle(color: Colors.white70),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text("Back"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: const Text("Scan the pairing QR code")),
      body: MobileScanner(
        controller: _controller,
        onDetect: _onDetect,
        errorBuilder: _error,
      ),
    );
  }
}
