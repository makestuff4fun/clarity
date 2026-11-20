// Acceptance: clarity/pair-app. Copied into budget/test/den_accept/ by check_pair_app.sh.
// Every way of pairing (typed bare code, typed/pasted link, scanned link) must reach the same
// redeem with the right code and base URL; a QR that is not a Clarity link is refused by name.
// The codes here are invented (not from any red), and nothing is redeemed for real.
import 'package:budget/struct/backend/clarityServer.dart';
import 'package:budget/struct/clarityPairInput.dart';
import 'package:budget/widgets/clarityPairForm.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

final redeemed = <List<String>>[];
final refused = <PairRefusal>[];

Future<bool> run(String text, PairSource source) => pairFromInput(text,
    source: source,
    redeem: (l) async => redeemed.add([l.code, l.baseUrl]),
    refuse: refused.add);

const red = ClarityServer.kServerUrl;

void main() {
  setUp(() {
    redeemed.clear();
    refused.clear();
  });

  test('typed bare code redeems with red', () async {
    expect(await run('  Alpha bravo-Charlie  delta ', PairSource.typed), isTrue);
    expect(redeemed, [['alpha bravo charlie delta', red]]);
    expect(refused, isEmpty);
  });

  test('typed full link redeems with its code and the default base URL', () async {
    expect(await run('clarity://provision?code=alpha%20bravo%20charlie', PairSource.typed), isTrue);
    expect(redeemed, [['alpha bravo charlie', red]]);
  });

  test('typed link with url= on a red host uses that base URL', () async {
    expect(
        await run('clarity://provision?code=echo%20fox&url=https%3A%2F%2Fclarity.hanquest.com%3A62280%2Fx',
            PairSource.typed),
        isTrue);
    expect(redeemed, [['echo fox', 'https://clarity.hanquest.com:62280']]);
  });

  test('scanned clarity link redeems', () async {
    expect(await run('clarity://provision?code=golf%20hotel&url=http%3A%2F%2F127.0.0.1%3A8765', PairSource.scanned),
        isTrue);
    expect(redeemed, [['golf hotel', 'http://127.0.0.1:8765']]);
  });

  test('scanned non-Clarity QR is refused by name, never redeemed', () async {
    for (final qr in ['https://example.com/menu', 'WIFI:S:home;T:WPA;P:x;;', 'just some words']) {
      expect(await run(qr, PairSource.scanned), isFalse);
    }
    expect(redeemed, isEmpty);
    expect(refused.length, 3);
    expect(refused.every((r) => r.title == 'Not a Clarity pairing code'), isTrue);
  });

  test('a clarity link pointing away from red is refused as handleProvisionLink does', () async {
    expect(await run('clarity://provision?code=india&url=https%3A%2F%2Fevil.example', PairSource.scanned), isFalse);
    expect(await run('clarity://provision', PairSource.typed), isFalse);
    expect(redeemed, isEmpty);
    expect(refused.map((r) => r.title), ['Pairing link not usable', 'Pairing link not usable']);
  });

  test('empty or junk typed text is refused', () async {
    expect(await run('   ', PairSource.typed), isFalse);
    expect(await run('https://example.com', PairSource.typed), isFalse);
    expect(await run('code; rm', PairSource.typed), isFalse);
    expect(redeemed, isEmpty);
    expect(refused.length, 3);
  });

  Widget host(List<String> submitted, List<int> scans) => MaterialApp(
        home: Scaffold(
          body: ClarityPairForm(onScan: () => scans.add(1), onSubmit: submitted.add),
        ),
      );

  testWidgets('type a code and tap Pair submits it; camera button scans', (t) async {
    final submitted = <String>[];
    final scans = <int>[];
    await t.pumpWidget(host(submitted, scans));
    await t.enterText(find.byKey(ClarityPairForm.fieldKey), 'kilo lima');
    await t.tap(find.byKey(ClarityPairForm.pairButtonKey));
    await t.tap(find.byKey(ClarityPairForm.scanButtonKey));
    await t.pump();
    expect(submitted, ['kilo lima']);
    expect(scans, [1]);
  });

  testWidgets('paste is one tap and submits the clipboard', (t) async {
    final submitted = <String>[];
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') return {'text': ' clarity://provision?code=mike%20nov \n'};
      return null;
    });
    await t.pumpWidget(host(submitted, []));
    await t.tap(find.byKey(ClarityPairForm.pasteButtonKey));
    await t.pumpAndSettle();
    expect(submitted, ['clarity://provision?code=mike%20nov']);
    expect(readPairInput(submitted.single).link!.code, 'mike nov');
  });
}
