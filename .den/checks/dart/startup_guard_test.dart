// Acceptance: clarity-startup. A startup failure is never silent (Clarity 5.5.0 froze on the
// splash: constructDb threw in main(), the zone swallowed it, runApp was never reached).
// Copied into budget/test/den_accept/startup_guard/ by check_startup.sh.
import 'package:budget/struct/startupGuard.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Widget theApp() => const MaterialApp(home: Text("THE APP"));

void main() {
  late List<Widget> shown;
  setUp(() {
    resetStartupGuardForTest();
    shown = [];
  });

  testWidgets("a throwing essential step shows the error screen, not the app", (tester) async {
    final ran = <String>[];
    final ok = await runStartup(
      steps: [
        StartupStep("prefs", () => ran.add("prefs")),
        StartupStep("database", () => throw StateError("no libsqlite3.so\nsecond line")),
        StartupStep("settings", () => ran.add("settings")),
      ],
      app: theApp,
      show: shown.add,
    );
    expect(ok, isFalse);
    expect(ran, ["prefs"], reason: "startup stops at the failing essential step");
    expect(shown, hasLength(1));
    await tester.pumpWidget(shown.single);
    expect(find.text("Clarity could not start"), findsOneWidget);
    expect(find.text("Bad state: no libsqlite3.so"), findsOneWidget, reason: "the error's first line");
    expect(find.text("second line"), findsNothing);
    expect(find.text("Copy details"), findsOneWidget);
    expect(find.text("Try again"), findsOneWidget);
    expect(find.text("THE APP"), findsNothing);
  });

  testWidgets("a throwing optional step falls back and the app still opens", (tester) async {
    final ran = <String>[];
    var fellBack = false;
    final ok = await runStartup(
      steps: [
        StartupStep("database", () => ran.add("database")),
        StartupStep("notifications", () => throw Exception("no notification channel"),
            essential: false, fallback: () => fellBack = true),
        StartupStep("time zone", () async => throw Exception("bad zone"), essential: false),
        StartupStep("settings", () => ran.add("settings")),
      ],
      app: theApp,
      show: shown.add,
    );
    expect(ok, isTrue);
    expect(fellBack, isTrue);
    expect(ran, ["database", "settings"]);
    await tester.pumpWidget(shown.single);
    expect(find.text("THE APP"), findsOneWidget);
    expect(find.text("Clarity could not start"), findsNothing);
  });

  testWidgets("Try again reruns startup and opens the app once it works", (tester) async {
    var attempts = 0;
    await runStartup(
      steps: [
        StartupStep("database", () {
          attempts++;
          if (attempts == 1) throw StateError("locked");
        }),
      ],
      app: theApp,
      show: (w) => shown.add(w),
    );
    await tester.pumpWidget(shown.last);
    expect(find.text("Clarity could not start"), findsOneWidget);
    await tester.tap(find.text("Try again"));
    await tester.pump();
    expect(attempts, 2);
    await tester.pumpWidget(shown.last);
    expect(find.text("THE APP"), findsOneWidget);
  });

  testWidgets("Copy details puts the error and stack on the clipboard", (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == "Clipboard.setData") copied = (call.arguments as Map)["text"] as String?;
      return null;
    });
    await runStartup(
      steps: [StartupStep("database", () => throw StateError("disk full"))],
      app: theApp,
      show: shown.add,
    );
    await tester.pumpWidget(shown.single);
    await tester.tap(find.text("Copy details"));
    await tester.pump();
    expect(copied, contains("disk full"));
    expect(copied, contains("Clarity could not start"));
  });

  testWidgets("an uncaught error before the first frame shows the error screen", (tester) async {
    // the app has been handed to runApp but has not drawn a frame yet
    await runStartup(steps: [], app: theApp, show: shown.add);
    expect(startupFirstFrameDrawn, isFalse);
    handleStartupZoneError(StateError("boom before frame"), StackTrace.current);
    expect(shown, hasLength(2));
    await tester.pumpWidget(shown.last);
    expect(find.text("Clarity could not start"), findsOneWidget);
    expect(find.text("Bad state: boom before frame"), findsOneWidget);
  });

  testWidgets("an uncaught error after the first frame leaves the app running", (tester) async {
    await runStartup(steps: [], app: theApp, show: shown.add);
    await tester.pumpWidget(shown.single);
    await tester.pump();
    expect(startupFirstFrameDrawn, isTrue);
    handleStartupZoneError(StateError("late error"), StackTrace.current);
    expect(shown, hasLength(1), reason: "no error screen after the first frame");
    expect(find.text("THE APP"), findsOneWidget);
  });
}
