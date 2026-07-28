# Clarity

A private, offline-first personal finance app for Android, iOS, and the web.

Clarity tracks transactions, budgets, savings goals, and recurring subscriptions
across multiple accounts and currencies. Everything is stored locally in SQLite.
Nothing is sent anywhere.

---

## Attribution and licence

Clarity is a derivative work of **[Cashew](https://github.com/jameskokoska/Cashew)**
by James Kokoska, used under the **GNU General Public License v3.0**.

Clarity is likewise licensed under **GPL-3.0** — see [LICENSE](LICENSE). If you
distribute Clarity, in source or binary form, you must keep it under GPL-3.0,
retain this attribution, and make your source available.

### Changes made in this fork

As required by GPL-3.0 §5(a), the significant modifications are:

- **Removed all Google and Firebase integration.** Firebase Auth, Cloud
  Firestore, Google Sign-In, Google Drive backups, the Gmail API, and reCAPTCHA
  Enterprise are gone, along with the upstream Firebase project configuration
  and API keys that were embedded in the web build.
- **Introduced a pluggable backend layer.** Account sign-in, backup storage,
  attachments, shared budgets, and email scanning now sit behind interfaces in
  `budget/lib/struct/backend/syncBackend.dart`. The shipped implementations are
  unconfigured stubs; the UI for these features is intact but inert until a
  backend is registered.
- **Removed the premium tier.** The in-app purchase flow, the upsell page, the
  paywall prompts, and every locked-feature gate are gone. All features are
  unconditionally available.
- **Removed telemetry and upstream links.** In-app feedback is no longer
  transmitted; links to the upstream website, FAQ, store listings, and issue
  tracker have been removed.
- **Upgraded to current toolchains.** Flutter 3.41 / Dart 3.11, and the Android
  build moved from AGP 7.3 / Gradle 7.5 / Java 8 to AGP 8.7 / Gradle 8.11 /
  Java 17, compiling against SDK 36.
- **Rebranded** the application name and identifiers.

The database schema is **unchanged** from upstream, deliberately — see below.

---

## Migrating your existing Cashew data

Your data is portable. Clarity uses the exact same database schema as Cashew
(schema version 46), so a Cashew backup imports directly.

Clarity also installs under a **different application ID**
(`com.clarity.finance` rather than `com.budget.tracker_app`), so it sits
alongside Cashew rather than replacing it. **Do not uninstall Cashew until you
have confirmed your data is in Clarity.**

### Steps

1. **In Cashew:** go to *Settings → Backups → Export database*. This writes a
   `.sqlite` file to your device.
2. Move that file somewhere Clarity can reach it (local storage is fine).
3. **In Clarity:** go to *Settings → Import data file*, pick the `.sqlite`, and
   confirm the overwrite warning.
4. Restart the app when prompted.

Your transactions, budgets, categories, wallets, goals, and **app preferences**
all come across — Cashew stores its settings inside the database, so they travel
with the backup. Settings that Clarity no longer has are ignored harmlessly.

### If your only backup is in Google Drive

Cashew's automatic backups live in Drive's hidden `appDataFolder`, which is
**not visible** in the Google Drive web interface or app. You cannot retrieve
them without Cashew. Open Cashew, go to *Settings → Backups*, and use the
download button next to a backup to save it to your device first.

Do this **before** uninstalling Cashew.

### Older Cashew versions

Backups from any Cashew release back to schema version 9 will be migrated
forward automatically on import. Backups from a *newer* Cashew than this fork
was branched from will not open.

---

## Wiring up your own sync

Clarity ships with no cloud backend. The seams are defined in
`budget/lib/struct/backend/syncBackend.dart`:

| Interface           | Covers                                       |
| ------------------- | -------------------------------------------- |
| `SyncBackend`       | Account sign-in, backup upload/download/list |
| `AttachmentBackend` | Transaction attachments                      |
| `ShareBackend`      | Shared/collaborative budgets                 |
| `MailBackend`       | Email scanning for auto-transactions         |
| `FeedbackBackend`   | In-app feedback (default: discards it)       |

Implement whichever you need and register them at startup:

```dart
configureBackends(
  sync: MySyncBackend(),
  attachment: MyAttachmentBackend(),
);
```

Until then, those code paths raise `BackendNotConfigured`, which the app already
surfaces through its normal error handling. Backup, sync, and shared-budget
screens remain reachable and simply report that the feature is unavailable.
Everything local — transactions, budgets, goals, reports, CSV import/export,
local database export/import — works fully offline with no backend at all.

---

## Building

```bash
cd budget
flutter pub get
flutter build apk          # Android
flutter build web          # Web
```

Requires Flutter 3.41+ and JDK 17+.

Release Android builds are signed from `android/key.properties` if present, and
fall back to the debug key otherwise.
