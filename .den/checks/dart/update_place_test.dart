// Acceptance: clarity-update-place. "Check for updates" in Settings (under "App"), beside the
// version on the About page, and on the More tile, all on one check state and one download.
// A fake check (a Completer) and a fake clock relative to DateTime.now(); no calendar day or
// wall-clock time is written down here.
import 'dart:async';
import 'dart:io';

import 'package:budget/struct/update/updateAction.dart';
import 'package:budget/struct/update/updateChecker.dart';
import 'package:budget/struct/update/updateDownload.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeDownloader extends UpdateDownloader {
  UpdateSnapshot s = const UpdateSnapshot();
  FakeDownloader()
      : super(dir: () => Directory.systemTemp, install: (_) async => true, autoTick: false);
  @override
  UpdateSnapshot get snapshot => s;
  void show(UpdateSnapshot next) {
    s = next;
    notifyListeners();
  }
}

const newer = UpdateInfo(
    versionCode: 999, versionName: "9.9.9", sha256: "00", url: "clarity-9.9.9.apk", notes: "");

void main() {
  late FakeDownloader dl;
  late UpdateCheckState state;
  late int checks;
  Completer<UpdateInfo?> answer = Completer();
  late DateTime now;
  late List<UpdateTap> outcomes;

  setUp(() {
    dl = FakeDownloader();
    checks = 0;
    now = DateTime.now();
    outcomes = [];
    state = UpdateCheckState(
      check: () {
        checks++;
        answer = Completer(); // made in the test body zone, so the fake async flushes it
        return answer.future;
      },
      downloader: dl,
      now: () => now,
    );
  });

  void tap() => state.tap().then((r) => outcomes.add(r.$1));

  Widget app({bool supported = true}) => MaterialApp(
        home: Scaffold(
          body: ListView(children: [
            UpdateActionRow(
                supported: supported, versionName: "5.7.1", state: state, onTap: tap),
            UpdateActionButton(supported: supported, state: state, onTap: tap),
          ]),
        ),
      );

  testWidgets("Settings shows the row with the installed version; a tap runs the check once",
      (t) async {
    await t.pumpWidget(app());
    expect(find.text("Clarity 5.7.1 · Check for updates"), findsOneWidget);
    expect(find.byKey(const Key("update-action-status")), findsNothing);
    await t.tap(find.byKey(const Key("update-action")));
    await t.pump();
    expect(checks, 1);
    expect(find.text("Checking…"), findsNWidgets(2)); // the row and About: one state
    answer.complete(newer);
    await t.pump(); await t.pump(const Duration(seconds: 1));
    expect(outcomes, [UpdateTap.found]);
    expect(find.byKey(const Key("update-action-status")), findsNothing);
  });

  testWidgets("no update shows in place, then the time of the last check", (t) async {
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key("update-action")));
    answer.complete(null);
    await t.pump(); await t.pump(const Duration(seconds: 1));
    expect(outcomes, [UpdateTap.upToDate]);
    expect(find.text("Up to date · checked just now"), findsNWidgets(2));
    final at = now;
    now = at.add(const Duration(minutes: 5));
    await t.pumpWidget(app()); // a rebuild, as scrolling or reopening the page does
    expect(find.text("Up to date · checked 5 min ago"), findsNWidgets(2));
    // older than an hour: the clock time, or the day once it is not today
    final later = at.add(const Duration(hours: 2));
    String two(int n) => n.toString().padLeft(2, "0");
    final sameDay = later.year == at.year && later.month == at.month && later.day == at.day;
    expect(checkedAgo(at, later),
        sameDay ? "at ${two(at.hour)}:${two(at.minute)}" : "on ${at.year}-${two(at.month)}-${two(at.day)}");
    expect(checkedAgo(at, at.add(const Duration(days: 2))),
        "on ${at.year}-${two(at.month)}-${two(at.day)}");
  });

  testWidgets("the About page offers the action and it runs the same check", (t) async {
    await t.pumpWidget(app());
    expect(find.text("Check for updates"), findsOneWidget);
    await t.tap(find.byKey(const Key("update-about-action")));
    await t.pump();
    expect(checks, 1);
    expect(find.byKey(const Key("update-about-status")), findsOneWidget);
    expect(find.byKey(const Key("update-action-status")), findsOneWidget);
    answer.complete(null);
    await t.pump(); await t.pump(const Duration(seconds: 1));
    expect(find.text("Up to date · checked just now"), findsNWidgets(2));
  });

  testWidgets("a second tap during a check starts nothing, from any place", (t) async {
    await t.pumpWidget(app());
    await t.tap(find.byKey(const Key("update-action")));
    await t.pump();
    await t.tap(find.byKey(const Key("update-action")));
    await t.tap(find.byKey(const Key("update-about-action")));
    await t.pump();
    expect(checks, 1);
    expect(outcomes, [UpdateTap.busy, UpdateTap.busy]);
    // the silent check on start also waits its turn
    expect(await state.background(), isNull);
    expect(checks, 1);
    answer.complete(null);
    await t.pump(); await t.pump(const Duration(seconds: 1));
    expect(outcomes, [UpdateTap.busy, UpdateTap.busy, UpdateTap.upToDate]);
  });

  testWidgets("a running download's block shows under the Settings row; a tap shows it, checks nothing",
      (t) async {
    await t.pumpWidget(app());
    expect(find.byKey(const Key("update-block")), findsNothing);
    dl.show(const UpdateSnapshot(
        phase: UpdatePhase.downloading, versionName: "9.9.9", done: 100, total: 400));
    await t.pump();
    expect(find.byKey(const Key("update-block")), findsOneWidget);
    expect(find.text("Downloading Clarity 9.9.9"), findsOneWidget);
    final rowTop = t.getTopLeft(find.byKey(const Key("update-action"))).dy;
    final blockTop = t.getTopLeft(find.byKey(const Key("update-block"))).dy;
    expect(blockTop, greaterThan(rowTop));
    expect(
        find.descendant(
            of: find.byKey(const Key("update-action-row")),
            matching: find.byKey(const Key("update-block"))),
        findsOneWidget);
    await t.tap(find.byKey(const Key("update-action")));
    await t.tap(find.byKey(const Key("update-about-action")));
    await t.pump();
    expect(checks, 0);
    expect(outcomes, [UpdateTap.showDownload, UpdateTap.showDownload]);
    dl.show(const UpdateSnapshot());
    await t.pump();
    expect(find.byKey(const Key("update-block")), findsNothing);
  });

  testWidgets("none of it shows when selfUpdateSupported is false", (t) async {
    dl.show(const UpdateSnapshot(
        phase: UpdatePhase.downloading, versionName: "9.9.9", done: 100, total: 400));
    await t.pumpWidget(app(supported: false));
    expect(find.byKey(const Key("update-action-row")), findsNothing);
    expect(find.byKey(const Key("update-about")), findsNothing);
    expect(find.byKey(const Key("update-block")), findsNothing);
    expect(find.textContaining("Check for updates"), findsNothing);
  });
}
