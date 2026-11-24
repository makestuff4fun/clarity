// The update block: the same view in the popup that opens on "Update" and in Settings under
// "Check for updates". Plain Material widgets on Clarity's theme, so it is widget-tested with
// no app state (.den/checks/dart/update_progress_test.dart).
import 'package:budget/struct/update/updateDownload.dart';
import 'package:flutter/material.dart';

class UpdateProgressView extends StatelessWidget {
  final UpdateSnapshot s;
  final VoidCallback? onCancel, onRetry, onInstall;
  const UpdateProgressView(
      {super.key, required this.s, this.onCancel, this.onRetry, this.onInstall});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final body = theme.textTheme.bodyMedium;
    final faint = body?.copyWith(color: cs.onSurface.withOpacity(0.7));
    final lines = <Widget>[];
    String title;
    switch (s.phase) {
      case UpdatePhase.idle:
        return const SizedBox.shrink();
      case UpdatePhase.downloading:
      case UpdatePhase.stalled:
        title = "Downloading Clarity ${s.versionName}";
        break;
      case UpdatePhase.failed:
        title = "Clarity ${s.versionName} did not download";
        break;
      case UpdatePhase.verified:
        title = "Clarity ${s.versionName} is downloaded and verified";
        break;
      case UpdatePhase.needsPermission:
        title = "Clarity ${s.versionName} is downloaded and verified";
        break;
    }
    lines.add(Text(title, key: const Key("update-title"),
        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)));
    lines.add(const SizedBox(height: 10));
    if (s.phase == UpdatePhase.downloading || s.phase == UpdatePhase.stalled ||
        s.phase == UpdatePhase.failed) {
      lines.add(ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: LinearProgressIndicator(
          key: const Key("update-bar"),
          value: s.fraction,
          minHeight: 8,
          color: s.phase == UpdatePhase.failed ? cs.error : cs.primary,
          backgroundColor: cs.primary.withOpacity(0.15),
        ),
      ));
      lines.add(const SizedBox(height: 8));
      lines.add(Row(children: [
        if (s.percent != null)
          Text("${s.percent}%", key: const Key("update-percent"), style: body),
        const Spacer(),
        Text(formatDoneOfTotal(s.done, s.total),
            key: const Key("update-size"), style: body),
      ]));
    }
    if (s.phase == UpdatePhase.downloading) {
      lines.add(Row(children: [
        if (s.speed > 0)
          Text(formatSpeed(s.speed), key: const Key("update-speed"), style: faint),
        const Spacer(),
        if (s.secondsLeft != null)
          Text(formatTimeLeft(s.secondsLeft!),
              key: const Key("update-left"), style: faint),
      ]));
    } else if (s.phase == UpdatePhase.stalled) {
      lines.add(Text("Waiting for the network",
          key: const Key("update-stalled"), style: faint));
    } else if (s.phase == UpdatePhase.failed) {
      lines.add(const SizedBox(height: 4));
      lines.add(Text(s.message ?? "The download stopped.",
          key: const Key("update-error"), style: body?.copyWith(color: cs.error)));
    } else if (s.phase == UpdatePhase.verified) {
      lines.add(Text("Opening Android's installer…",
          key: const Key("update-verified"), style: faint));
    } else if (s.phase == UpdatePhase.needsPermission) {
      lines.add(Text(s.message ?? "Allow Clarity to install apps, then tap Install",
          key: const Key("update-permission"), style: faint));
    }
    final buttons = <Widget>[
      if (s.phase == UpdatePhase.failed || s.phase == UpdatePhase.needsPermission ||
          s.phase == UpdatePhase.downloading || s.phase == UpdatePhase.stalled)
        TextButton(
            key: const Key("update-cancel"), onPressed: onCancel, child: const Text("Cancel")),
      if (s.phase == UpdatePhase.failed)
        FilledButton(
            key: const Key("update-retry"), onPressed: onRetry, child: const Text("Retry")),
      if (s.phase == UpdatePhase.needsPermission)
        FilledButton(
            key: const Key("update-install"),
            onPressed: onInstall,
            child: const Text("Install")),
    ];
    if (buttons.isNotEmpty) {
      lines.add(const SizedBox(height: 6));
      lines.add(Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [for (final b in buttons) Padding(
              padding: const EdgeInsetsDirectional.only(start: 8), child: b)]));
    }
    return Column(
        key: const Key("update-block"),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: lines);
  }
}

/// The view, live on a downloader (repaints on each tick).
class UpdateProgressBlock extends StatelessWidget {
  final UpdateDownloader downloader;
  final EdgeInsetsGeometry padding;
  const UpdateProgressBlock(
      {super.key, required this.downloader, this.padding = EdgeInsets.zero});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: downloader,
        builder: (context, _) {
          final s = downloader.snapshot;
          if (!s.active) return const SizedBox.shrink();
          return Padding(
            padding: padding,
            child: UpdateProgressView(
              s: s,
              onCancel: downloader.cancel,
              onRetry: downloader.retry,
              onInstall: downloader.installReady,
            ),
          );
        },
      );
}
