// A startup failure is never silent.
//
// Clarity 5.5.0 froze on the splash screen for ever: the APK carried no libsqlite3.so, so
// `constructDb` threw in main(), captureLogs's zone swallowed the error, and runApp was never
// reached. Now main() runs its init as a list of [StartupStep]s through [runStartup]:
//  - every failure is written to logcat under the tag `clarity` (error and stack), through liblog
//    directly, since a plain print is captured by the logging zone;
//  - an essential step failing (or any uncaught error before the first frame) replaces the splash
//    with [StartupErrorScreen]: "Clarity could not start", the error's first line, Copy details and
//    Try again;
//  - an optional step failing logs, runs its fallback (a sane default) and the app opens anyway.
// Errors after the first frame keep the old behaviour (the app carries on), plus the logcat line.
//
// Keep this file free of app imports: the startup guard test loads it on its own.
import 'dart:async';

import 'package:budget/struct/logcat.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const String startupLogTag = "clarity";

class StartupStep {
  const StartupStep(this.name, this.run, {this.essential = true, this.fallback});

  final String name;
  final FutureOr<void> Function() run;

  /// An essential step failing shows [StartupErrorScreen]; an optional one is logged, then
  /// [fallback] sets a sane default and startup carries on.
  final bool essential;
  final FutureOr<void> Function()? fallback;
}

/// Writes [what], the error and its stack to logcat (tag `clarity`) and to the console.
void logStartupError(String what, Object error, StackTrace? stack) {
  final String text = "$what: $error\n${stack ?? ''}";
  try {
    logcatError(startupLogTag, text);
  } catch (_) {}
  Zone.root.print("[$startupLogTag] $text");
}

typedef ShowWidget = void Function(Widget widget);

bool _firstFrameDrawn = false;
bool _errorShown = false;
ShowWidget _show = runApp;
Future<bool> Function()? _retry;

/// True once the real app has drawn its first frame.
bool get startupFirstFrameDrawn => _firstFrameDrawn;

/// Runs [steps] in order, then shows [app] and calls [onStarted]. Returns false (and shows
/// [StartupErrorScreen]) when an essential step fails. [show] is `runApp` except in tests.
Future<bool> runStartup({
  required List<StartupStep> steps,
  required Widget Function() app,
  void Function()? onStarted,
  ShowWidget show = runApp,
}) async {
  _show = show;
  _retry = () => runStartup(steps: steps, app: app, onStarted: onStarted, show: show);
  _errorShown = false;
  for (final StartupStep step in steps) {
    try {
      await step.run();
    } catch (error, stack) {
      if (step.essential) {
        logStartupError("Startup failed at ${step.name}", error, stack);
        _showError(error, stack);
        return false;
      }
      logStartupError("Startup step ${step.name} failed; continuing without it", error, stack);
      try {
        await step.fallback?.call();
      } catch (error, stack) {
        logStartupError("Fallback for ${step.name} failed", error, stack);
      }
    }
  }
  try {
    show(app());
    WidgetsBinding.instance.addPostFrameCallback((_) => _firstFrameDrawn = true);
  } catch (error, stack) {
    logStartupError("Startup failed showing the app", error, stack);
    _showError(error, stack);
    return false;
  }
  onStarted?.call();
  return true;
}

/// The logging zone's error handler (see captureLogs): logs every uncaught error to logcat, and
/// before the first frame also shows [StartupErrorScreen] instead of leaving the splash up.
void handleStartupZoneError(Object error, StackTrace stack) {
  if (_firstFrameDrawn) {
    logStartupError("Uncaught error", error, stack);
    return;
  }
  logStartupError("Uncaught error before the first frame", error, stack);
  if (!_errorShown) _showError(error, stack);
}

void _showError(Object error, StackTrace? stack) {
  _errorShown = true;
  try {
    _show(StartupErrorScreen(error: error, stack: stack, onRetry: _retry));
  } catch (e, s) {
    logStartupError("Could not show the startup error screen", e, s);
  }
}

@visibleForTesting
void resetStartupGuardForTest() {
  _firstFrameDrawn = false;
  _errorShown = false;
  _show = runApp;
  _retry = null;
}

/// Shown instead of the splash when Clarity cannot start. Plain on purpose: no translations,
/// settings or theme, since any of those may be what failed.
class StartupErrorScreen extends StatefulWidget {
  const StartupErrorScreen({super.key, required this.error, this.stack, this.onRetry});

  final Object error;
  final StackTrace? stack;
  final Future<bool> Function()? onRetry;

  String get firstLine {
    final String s = error.toString().trim();
    final String line = s.split('\n').first.trim();
    return line.isEmpty ? error.runtimeType.toString() : line;
  }

  String get details => "Clarity could not start\n\n$error\n\n${stack ?? ''}";

  @override
  State<StartupErrorScreen> createState() => _StartupErrorScreenState();
}

class _StartupErrorScreenState extends State<StartupErrorScreen> {
  bool _retrying = false;
  final GlobalKey<ScaffoldMessengerState> _messenger = GlobalKey();

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.details));
    _messenger.currentState
        ?.showSnackBar(const SnackBar(content: Text("Details copied")));
  }

  Future<void> _tryAgain() async {
    final retry = widget.onRetry;
    if (retry == null || _retrying) return;
    setState(() => _retrying = true);
    try {
      await retry();
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: "Clarity",
      scaffoldMessengerKey: _messenger,
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "Clarity could not start",
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                SelectableText(widget.firstLine, style: const TextStyle(fontSize: 16)),
                const SizedBox(height: 24),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    OutlinedButton(onPressed: _copy, child: const Text("Copy details")),
                    FilledButton(
                      onPressed: widget.onRetry == null || _retrying ? null : _tryAgain,
                      child: const Text("Try again"),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
