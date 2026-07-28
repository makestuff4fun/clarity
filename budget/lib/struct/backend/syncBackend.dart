import 'dart:typed_data';

/// Thrown by every stubbed backend call.
///
/// Clarity ships without a cloud provider. All remote features (account
/// sign-in, backups, attachments, shared budgets, email scanning) are routed
/// through the interfaces in this directory. Supply real implementations and
/// register them via [configureBackends] to bring those code paths to life.
class BackendNotConfigured implements Exception {
  final String feature;
  const BackendNotConfigured(this.feature);

  @override
  String toString() =>
      "$feature is unavailable: no sync backend has been configured.";
}

/// An account authenticated against the sync backend.
class SyncAccount {
  final String id;
  final String email;
  final String? displayName;
  final String? photoUrl;

  const SyncAccount({
    required this.id,
    required this.email,
    this.displayName,
    this.photoUrl,
  });
}

/// A file held by the sync backend.
///
/// Mirrors the subset of file metadata the app actually reads and writes.
/// Fields are mutable because callers build these up before an upload.
class SyncFile {
  String? id;
  String? name;
  DateTime? modifiedTime;
  int? size;
  String? description;
  String? webViewLink;
  String? mimeType;
  List<String>? parents;

  SyncFile({
    this.id,
    this.name,
    this.modifiedTime,
    this.size,
    this.description,
    this.webViewLink,
    this.mimeType,
    this.parents,
  });
}

/// Account and file storage used for database backups and device sync.
abstract class SyncBackend {
  /// The account currently signed in, or null.
  SyncAccount? get currentAccount;

  /// Sign in. [silent] requests a non-interactive attempt; implementations
  /// that cannot do so should return null rather than prompting.
  Future<SyncAccount?> signIn({bool silent = false});

  Future<void> signOut();

  /// Files visible to the app, newest first. [nameContains] filters by
  /// substring when supplied.
  Future<List<SyncFile>> listFiles({String? nameContains});

  Future<SyncFile> uploadFile({
    required String name,
    required Uint8List bytes,
    String? description,
    bool appData = true,
  });

  Future<Uint8List> downloadFile(String fileId);

  Future<void> deleteFile(String fileId);
}

/// Storage for transaction attachments (photos, receipts, documents).
abstract class AttachmentBackend {
  /// Uploads [bytes] and returns a link the app can store on a transaction,
  /// or null if the upload was cancelled.
  Future<String?> uploadAttachment({
    required String name,
    required Uint8List bytes,
  });

  /// Fetches an attachment previously returned by [uploadAttachment].
  /// [onProgress] receives a 0..1 fraction when the total size is known.
  Future<List<int>> downloadAttachment(
    String link, {
    void Function(double progress)? onProgress,
  });
}

/// A shared budget as stored remotely. [data] holds the budget fields the app
/// writes in [ShareBackend.createSharedBudget].
class SharedBudgetSnapshot {
  final String id;
  final Map<String, dynamic> data;
  const SharedBudgetSnapshot({required this.id, required this.data});
}

/// One entry in a shared budget's transaction log. [data] carries a "logType"
/// of "create", "update", or "delete" plus the transaction fields.
class SharedTransactionLog {
  final String id;
  final Map<String, dynamic> data;
  const SharedTransactionLog({required this.id, required this.data});
}

/// Collaborative budgets shared across accounts.
///
/// Modelled as an append-mostly log per budget, which is what the sync
/// reconciliation in `shareBudget.dart` expects.
abstract class ShareBackend {
  /// Identity of the signed-in user, used to attribute ownership. Both are
  /// null when signed out.
  String? get currentUserEmail;
  String? get currentUserId;

  /// Creates a shared budget from [budgetEntry] and returns its key.
  Future<String> createSharedBudget(Map<String, dynamic> budgetEntry);

  /// Deletes the budget and its whole transaction log.
  Future<void> deleteSharedBudget(String sharedKey);

  /// Merges [fields] into the budget's stored metadata.
  Future<void> updateSharedBudget(
    String sharedKey,
    Map<String, dynamic> fields,
  );

  /// Adds or removes [member] from the budget's member list.
  Future<void> updateMembers(
    String sharedKey,
    String member, {
    required bool add,
  });

  /// The budget's stored fields, or null if it no longer exists.
  Future<Map<String, dynamic>?> getSharedBudget(String sharedKey);

  /// Every budget the signed-in user owns or is a member of.
  Future<List<SharedBudgetSnapshot>> listSharedBudgets();

  /// Log entries for [sharedKey], optionally only those updated after [since].
  Future<List<SharedTransactionLog>> listTransactionLogs(
    String sharedKey, {
    DateTime? since,
  });

  /// Writes [data] at [transactionKey], merging with any existing entry.
  Future<void> setTransactionLog(
    String sharedKey,
    String? transactionKey,
    Map<String, dynamic> data,
  );

  /// Appends [data] as a new entry and returns its key.
  Future<String> addTransactionLog(
    String sharedKey,
    Map<String, dynamic> data,
  );

  Future<void> deleteTransactionLog(String sharedKey, String transactionKey);
}

/// A single message retrieved from a mailbox.
class MailMessage {
  final String id;
  final String subject;
  final String from;
  final String body;
  final DateTime? receivedAt;

  const MailMessage({
    required this.id,
    required this.subject,
    required this.from,
    required this.body,
    this.receivedAt,
  });
}

/// Mailbox access used to auto-create transactions from receipt emails.
abstract class MailBackend {
  /// Whether the signed-in account has granted mailbox access.
  Future<bool> hasAccess();

  /// Messages matching [query], newest first.
  Future<List<MailMessage>> listMessages({String? query, int maxResults = 50});

  Future<void> markRead(String messageId);
}

/// Destination for in-app feedback submitted from the rating popup.
///
/// Upstream posted this to its own hosted database. Clarity has no such
/// endpoint, so the default implementation drops it locally.
abstract class FeedbackBackend {
  Future<void> submit(Map<String, dynamic> feedback);
}

// ---------------------------------------------------------------------------
// Stubs
//
// These are the implementations the app runs with today. Each throws
// [BackendNotConfigured]; callers already funnel remote failures through the
// app's snackbar/error handling, so the UI stays reachable and simply reports
// that the feature is unavailable.
// ---------------------------------------------------------------------------

class UnconfiguredSyncBackend implements SyncBackend {
  const UnconfiguredSyncBackend();

  @override
  SyncAccount? get currentAccount => null;

  @override
  Future<SyncAccount?> signIn({bool silent = false}) async {
    if (silent) return null;
    throw const BackendNotConfigured("Account sign-in");
  }

  @override
  Future<void> signOut() async {}

  @override
  Future<List<SyncFile>> listFiles({String? nameContains}) async =>
      throw const BackendNotConfigured("Backup listing");

  @override
  Future<SyncFile> uploadFile({
    required String name,
    required Uint8List bytes,
    String? description,
    bool appData = true,
  }) async =>
      throw const BackendNotConfigured("Backup upload");

  @override
  Future<Uint8List> downloadFile(String fileId) async =>
      throw const BackendNotConfigured("Backup download");

  @override
  Future<void> deleteFile(String fileId) async =>
      throw const BackendNotConfigured("Backup deletion");
}

class UnconfiguredAttachmentBackend implements AttachmentBackend {
  const UnconfiguredAttachmentBackend();

  @override
  Future<String?> uploadAttachment({
    required String name,
    required Uint8List bytes,
  }) async =>
      throw const BackendNotConfigured("Attachment upload");

  @override
  Future<List<int>> downloadAttachment(
    String link, {
    void Function(double progress)? onProgress,
  }) async =>
      throw const BackendNotConfigured("Attachment download");
}

class UnconfiguredShareBackend implements ShareBackend {
  const UnconfiguredShareBackend();

  Never _unavailable() => throw const BackendNotConfigured("Shared budgets");

  @override
  String? get currentUserEmail => null;

  @override
  String? get currentUserId => null;

  @override
  Future<String> createSharedBudget(Map<String, dynamic> budgetEntry) async =>
      _unavailable();

  @override
  Future<void> deleteSharedBudget(String sharedKey) async => _unavailable();

  @override
  Future<void> updateSharedBudget(
    String sharedKey,
    Map<String, dynamic> fields,
  ) async =>
      _unavailable();

  @override
  Future<void> updateMembers(
    String sharedKey,
    String member, {
    required bool add,
  }) async =>
      _unavailable();

  @override
  Future<Map<String, dynamic>?> getSharedBudget(String sharedKey) async =>
      _unavailable();

  @override
  Future<List<SharedBudgetSnapshot>> listSharedBudgets() async => _unavailable();

  @override
  Future<List<SharedTransactionLog>> listTransactionLogs(
    String sharedKey, {
    DateTime? since,
  }) async =>
      _unavailable();

  @override
  Future<void> setTransactionLog(
    String sharedKey,
    String? transactionKey,
    Map<String, dynamic> data,
  ) async =>
      _unavailable();

  @override
  Future<String> addTransactionLog(
    String sharedKey,
    Map<String, dynamic> data,
  ) async =>
      _unavailable();

  @override
  Future<void> deleteTransactionLog(
    String sharedKey,
    String transactionKey,
  ) async =>
      _unavailable();
}

class UnconfiguredMailBackend implements MailBackend {
  const UnconfiguredMailBackend();

  @override
  Future<bool> hasAccess() async => false;

  @override
  Future<List<MailMessage>> listMessages({
    String? query,
    int maxResults = 50,
  }) async =>
      throw const BackendNotConfigured("Email scanning");

  @override
  Future<void> markRead(String messageId) async =>
      throw const BackendNotConfigured("Email scanning");
}

/// Discards feedback rather than transmitting it anywhere.
class LocalOnlyFeedbackBackend implements FeedbackBackend {
  const LocalOnlyFeedbackBackend();

  @override
  Future<void> submit(Map<String, dynamic> feedback) async {
    // Intentionally not sent anywhere. Clarity does not phone home.
  }
}

// ---------------------------------------------------------------------------
// Registry
// ---------------------------------------------------------------------------

SyncBackend syncBackend = const UnconfiguredSyncBackend();
AttachmentBackend attachmentBackend = const UnconfiguredAttachmentBackend();
ShareBackend shareBackend = const UnconfiguredShareBackend();
MailBackend mailBackend = const UnconfiguredMailBackend();
FeedbackBackend feedbackBackend = const LocalOnlyFeedbackBackend();

/// Swap in real implementations at startup.
void configureBackends({
  SyncBackend? sync,
  AttachmentBackend? attachment,
  ShareBackend? share,
  MailBackend? mail,
  FeedbackBackend? feedback,
}) {
  if (sync != null) syncBackend = sync;
  if (attachment != null) attachmentBackend = attachment;
  if (share != null) shareBackend = share;
  if (mail != null) mailBackend = mail;
  if (feedback != null) feedbackBackend = feedback;
}

/// The account currently signed in to the sync backend, or null.
///
/// Mirrors [SyncBackend.currentAccount] but is also assignable, since the UI
/// clears it eagerly on sign-out and error paths.
SyncAccount? syncUser;

/// True when a sync backend capable of real work has been registered.
bool get syncBackendConfigured => syncBackend is! UnconfiguredSyncBackend;

/// True when attachments can actually be uploaded and previewed.
bool get attachmentBackendConfigured =>
    attachmentBackend is! UnconfiguredAttachmentBackend;
