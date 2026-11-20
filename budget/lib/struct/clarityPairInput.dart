import 'package:budget/struct/backend/clarityServer.dart';

/// Where a piece of pairing text came from. A scanned QR must be a full
/// clarity://provision link; typed or pasted text may also be the bare code.
enum PairSource { typed, scanned }

/// A pairing input that will not be redeemed, with the message shown for it.
class PairRefusal {
  final String title;
  final String description;
  const PairRefusal(this.title, this.description);
}

const PairRefusal kRefuseEmpty = PairRefusal(
  "Nothing to pair with",
  "Type or paste the pairing code or the clarity:// link from red",
);

/// The same message handleProvisionLink shows for a bad clarity:// link.
const PairRefusal kRefuseBadLink = PairRefusal(
  "Pairing link not usable",
  "It has no code, or points somewhere other than red",
);

const PairRefusal kRefuseNotClarityQr = PairRefusal(
  "Not a Clarity pairing code",
  "This QR code is not a clarity://provision link. Scan the code red shows for pairing.",
);

const PairRefusal kRefuseNotClarityText = PairRefusal(
  "Not a Clarity pairing code",
  "This is neither a pairing code nor a clarity://provision link",
);

/// The result of reading pairing input: exactly one of [link] or [refusal].
class PairInput {
  final ProvisionLink? link;
  final PairRefusal? refusal;
  const PairInput.link(ProvisionLink this.link) : refusal = null;
  const PairInput.refused(PairRefusal this.refusal) : link = null;
}

final RegExp _bareCode = RegExp(r"^[A-Za-z0-9]+([\s\-]+[A-Za-z0-9]+)*$");

/// Reads what was scanned, typed or pasted. A clarity:// link goes through
/// [parseProvisionLink], whose host rules stay the gate; a bare code (words
/// separated by spaces or hyphens, as red prints it) pairs with red itself.
PairInput readPairInput(String raw, {PairSource source = PairSource.typed}) {
  final String text = raw.trim();
  if (text.isEmpty) {
    return const PairInput.refused(kRefuseEmpty);
  }
  final Uri? uri = Uri.tryParse(text);
  final bool hasScheme = uri != null && uri.scheme.isNotEmpty;
  if (hasScheme) {
    if (uri.scheme.toLowerCase() == "clarity") {
      final ProvisionLink? link = parseProvisionLink(uri);
      return link == null
          ? const PairInput.refused(kRefuseBadLink)
          : PairInput.link(link);
    }
    return PairInput.refused(source == PairSource.scanned
        ? kRefuseNotClarityQr
        : kRefuseNotClarityText);
  }
  if (source == PairSource.scanned) {
    return const PairInput.refused(kRefuseNotClarityQr);
  }
  if (!_bareCode.hasMatch(text)) {
    return const PairInput.refused(kRefuseNotClarityText);
  }
  // Same normalisation as red's normalize_code: lower case, single spaces.
  final String code = text
      .toLowerCase()
      .split(RegExp(r"[\s\-]+"))
      .where((w) => w.isNotEmpty)
      .join(" ");
  return PairInput.link(ProvisionLink(code, ClarityServer.kServerUrl));
}

/// Reads [raw] and either redeems it through [redeem] (the same path a
/// clarity://provision link takes) or shows the named refusal through
/// [refuse]. Returns true when [redeem] was called. Nothing is logged.
Future<bool> pairFromInput(
  String raw, {
  PairSource source = PairSource.typed,
  required Future<void> Function(ProvisionLink link) redeem,
  required void Function(PairRefusal refusal) refuse,
}) async {
  final PairInput input = readPairInput(raw, source: source);
  if (input.link == null) {
    refuse(input.refusal!);
    return false;
  }
  await redeem(input.link!);
  return true;
}
