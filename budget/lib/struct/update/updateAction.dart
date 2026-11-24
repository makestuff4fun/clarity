// "Check for updates" where a person looks for it: a row in Settings (under "App"), an action
// beside the version on the About page, and the tile on the More page. All three run the one
// check below and show its one state, and the one download (updates.dart's updateDownloader).
// Plain Material widgets and no app state, so it is widget-tested on its own
// (.den/checks/dart/update_place_test.dart).
import 'package:budget/struct/update/updateChecker.dart';
import 'package:budget/struct/update/updateDownload.dart';
import 'package:budget/struct/update/updateProgressBlock.dart';
import 'package:flutter/material.dart';

/// What a tap led to.
enum UpdateTap {
  /// A download is going (or waits for Retry / Install): show it, check nothing.
  showDownload,

  /// A check is already running: nothing new started.
  busy,

  /// The check found nothing newer (or the feed was unreachable: the checker cannot tell).
  upToDate,

  /// A newer release: offer it.
  found,
}

/// The app's one update check. Kept in memory: "last checked" is forgotten when the app
/// restarts, and the silent check on start fills it in again.
class UpdateCheckState extends ChangeNotifier {
  final Future<UpdateInfo?> Function() check;
  final UpdateDownloader downloader;
  final DateTime Function() now;
  UpdateCheckState({required this.check, required this.downloader, DateTime Function()? now})
      : now = now ?? DateTime.now;

  bool _checking = false;
  DateTime? _lastChecked;
  bool _upToDate = false;

  bool get checking => _checking;

  /// When the last check finished (null: none yet since the app started).
  DateTime? get lastChecked => _lastChecked;

  /// The last check found nothing newer.
  bool get upToDate => _lastChecked != null && _upToDate;

  /// The tap on any of the three places. [onStart] runs only when a check really starts.
  Future<(UpdateTap, UpdateInfo?)> tap({void Function()? onStart}) async {
    if (downloader.snapshot.active) return (UpdateTap.showDownload, null);
    if (_checking) return (UpdateTap.busy, null);
    final info = await _run(onStart);
    return info == null ? (UpdateTap.upToDate, null) : (UpdateTap.found, info);
  }

  /// The silent check on start: null when busy, downloading, or nothing newer.
  Future<UpdateInfo?> background() async {
    if (_checking || downloader.snapshot.active) return null;
    return _run(null);
  }

  Future<UpdateInfo?> _run(void Function()? onStart) async {
    _checking = true;
    notifyListeners();
    UpdateInfo? info;
    var answered = false;
    try {
      onStart?.call();
      info = await check();
      answered = true;
      return info;
    } finally {
      _checking = false;
      _lastChecked = now();
      _upToDate = answered && info == null;
      notifyListeners();
    }
  }

  /// The status line all three places show; null when there is nothing to say.
  String? status() {
    if (_checking) return "Checking…";
    if (upToDate) return "Up to date · checked ${checkedAgo(_lastChecked!, now())}";
    return null;
  }
}

/// "just now", "5 min ago", "at 14:05" (today), else "on 2026-11-23" style.
String checkedAgo(DateTime at, DateTime now) {
  final d = now.difference(at);
  if (d.inSeconds < 60) return "just now";
  if (d.inMinutes < 60) return "${d.inMinutes} min ago";
  String two(int n) => n.toString().padLeft(2, "0");
  if (at.year == now.year && at.month == now.month && at.day == now.day) {
    return "at ${two(at.hour)}:${two(at.minute)}";
  }
  return "on ${at.year}-${two(at.month)}-${two(at.day)}";
}

/// The Settings row: "Clarity 5.7.1 · Check for updates", the status under it, and the
/// download's block under the row while one runs. Nothing at all when [supported] is false.
class UpdateActionRow extends StatelessWidget {
  final bool supported;
  final String versionName;
  final UpdateCheckState state;
  final VoidCallback onTap;
  const UpdateActionRow({
    super.key,
    required this.supported,
    required this.versionName,
    required this.state,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (!supported) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([state, state.downloader]),
      builder: (context, _) {
        final status = state.status();
        return Column(
          key: const Key("update-action-row"),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              key: const Key("update-action"),
              contentPadding: const EdgeInsetsDirectional.symmetric(horizontal: 18),
              leading: state.checking
                  ? const SizedBox(
                      width: 24, height: 24,
                      child: Padding(
                        padding: EdgeInsets.all(3),
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      ))
                  : Icon(Icons.system_update_rounded, color: theme.colorScheme.primary),
              title: Text("Clarity $versionName · Check for updates",
                  key: const Key("update-action-title")),
              subtitle: status == null
                  ? null
                  : Text(status, key: const Key("update-action-status")),
              onTap: onTap,
            ),
            UpdateProgressBlock(
              downloader: state.downloader,
              padding: const EdgeInsetsDirectional.symmetric(horizontal: 18, vertical: 10),
            ),
          ],
        );
      },
    );
  }
}

/// The About page's action, beside the version it shows: a button and the status under it.
/// (The download's block goes under the page's app information, where it has the width.)
class UpdateActionButton extends StatelessWidget {
  final bool supported;
  final UpdateCheckState state;
  final VoidCallback onTap;
  const UpdateActionButton(
      {super.key, required this.supported, required this.state, required this.onTap});

  @override
  Widget build(BuildContext context) {
    if (!supported) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final status = state.status();
        return Column(
          key: const Key("update-about"),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextButton.icon(
              key: const Key("update-about-action"),
              onPressed: onTap,
              icon: const Icon(Icons.system_update_rounded),
              label: const Text("Check for updates"),
            ),
            if (status != null)
              Padding(
                padding: const EdgeInsetsDirectional.symmetric(horizontal: 12),
                child: Text(status,
                    key: const Key("update-about-status"),
                    style: Theme.of(context).textTheme.bodySmall),
              ),
          ],
        );
      },
    );
  }
}
