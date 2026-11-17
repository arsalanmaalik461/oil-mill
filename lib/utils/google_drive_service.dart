import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../db/database_helper.dart';

/// Google Drive backup for ledger PDFs & per-entry database JSON backups.
///
/// Uses the signed-in user's own Drive (scope: drive.file — the app can
/// only see files/folders it creates itself). All PDFs & backups go into a
/// folder named "Namat Oil Mill" in that Drive.
class GoogleDriveService {
  GoogleDriveService._();

  static final GoogleDriveService instance = GoogleDriveService._();

  /// Name of the Drive folder that receives the ledger PDFs and backups.
  static const String folderName = 'Namat Oil Mill';

  final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: [drive.DriveApi.driveFileScope],
  );

  /// The underlying [GoogleSignIn] instance (for silent session restore).
  GoogleSignIn get googleSignIn => _googleSignIn;

  /// The currently signed-in account, or null when signed out.
  GoogleSignInAccount? get currentAccount => _googleSignIn.currentUser;

  /// Email of the currently signed-in account, or null when signed
  /// out — what Settings shows so the user can see WHICH Google
  /// account this phone is connected to.
  String? get currentAccountEmail => _googleSignIn.currentUser?.email;

  /// Switches to a different Google account: signs the current one
  /// out, then runs the INTERACTIVE sign-in so the user gets the
  /// account chooser. The silent pre-attempt in [signIn] is
  /// deliberately skipped — after a sign-out it could silently
  /// re-select the same account, defeating the switch. Returns the
  /// newly signed-in account, or null when the user cancels or the
  /// switch fails. Never throws.
  Future<GoogleSignInAccount?> changeAccount() async {
    try {
      await _googleSignIn.signOut();
    } catch (_) {
      // Even if sign-out errors, still offer the account chooser.
    }
    try {
      return await _googleSignIn.signIn();
    } catch (_) {
      return null;
    }
  }

  /// Whether a user is currently signed in.
  Future<bool> isSignedIn() => _googleSignIn.isSignedIn();

  /// Attempts to restore a previously granted Google session with NO
  /// UI: succeeds when the Google account on this device has already
  /// authorized the app — the authorization belongs to the account,
  /// not to the phone it was first granted on. Never throws and never
  /// falls back to the interactive flow, so it is safe for status
  /// checks and background paths.
  ///
  /// Callers must use this rather than gating a silent sign-in behind
  /// [isSignedIn]: that check only reflects the plugin's cached
  /// session ON THIS DEVICE, so on a second phone it is false exactly
  /// when a restore should be attempted, and the account then wrongly
  /// shows as "not connected".
  Future<GoogleSignInAccount?> restoreSession() async {
    try {
      return await _googleSignIn.signInSilently();
    } catch (_) {
      // No restorable session / setup missing: simply not connected.
      return null;
    }
  }

  /// Why the most recent [signIn] attempt failed, in plain text
  /// (the platform exception's own words), or null when it succeeded
  /// or has not run yet. Settings shows this next to the generic
  /// "sign-in failed" message so a setup problem can be diagnosed
  /// from a screenshot instead of guessed at.
  String? lastSignInError;

  /// Signs in: tries a silent sign-in first (restores an existing
  /// session), then falls back to the interactive flow. Never throws:
  /// a failure is recorded in [lastSignInError] and null is returned.
  Future<GoogleSignInAccount?> signIn() async {
    lastSignInError = null;
    try {
      final silent = await _googleSignIn.signInSilently();
      if (silent != null) return silent;
    } catch (e) {
      lastSignInError = 'silent sign-in: $e';
    }
    try {
      final account = await _googleSignIn.signIn();
      if (account == null) {
        lastSignInError =
            'interactive sign-in ended without an account (cancelled or refused)';
      } else {
        lastSignInError = null;
      }
      return account;
    } catch (e) {
      lastSignInError = 'interactive sign-in: $e';
      return null;
    }
  }

  /// Signs the current user out.
  Future<void> signOut() => _googleSignIn.signOut();

  /// Uploads [bytes] as a PDF named [fileName] into the
  /// "Namat Oil Mill" Drive folder.
  Future<String> uploadPdf(Uint8List bytes, String fileName) async {
    if (currentAccount == null) {
      await signIn();
    }
    if (currentAccount == null) {
      throw StateError('Google sign-in required before uploading.');
    }
    final client = await _googleSignIn.authenticatedClient();
    if (client == null) {
      throw StateError('Could not create an authenticated Google client.');
    }
    try {
      final api = drive.DriveApi(client);
      final folderId = await _findOrCreateFolder(api);
      final media = drive.Media(Stream.value(bytes), bytes.length,
          contentType: 'application/pdf');
      final file = drive.File()
        ..name = fileName
        ..parents = [folderId]
        ..mimeType = 'application/pdf';
      final created = await api.files.create(file, uploadMedia: media);
      final id = created.id;
      if (id == null) {
        throw StateError('Drive upload finished without a file id.');
      }
      return id;
    } finally {
      client.close();
    }
  }

  /// The ONE Drive backup file name — fixed, no date in it. The
  /// Drive folder holds exactly one current backup: every sync
  /// replaces its content (see [_uploadSingleBackup]).
  static const String backupFileName = 'namat_backup.json';

  /// Whether a Drive file name is one of this app's backup files:
  /// the current fixed name, or a legacy dated name from the era
  /// when every upload created a new `namat_backup_<date>.json`.
  static bool isBackupFileName(String name) =>
      name.startsWith('namat_backup') && name.endsWith('.json');

  /// Rotation plan for the backup files in the Drive folder ([files]
  /// newest first): keep the newest file that already carries the
  /// fixed [backupFileName] and update it in place; delete every
  /// other backup file (legacy dated ones and duplicates), so
  /// exactly one current backup remains. Non-backup files are never
  /// in the plan. keepId is null when no fixed-name file exists yet
  /// (the caller creates it, and all dated files are deleted).
  static ({String? keepId, List<String> deleteIds}) planBackupRotation(
      List<({String id, String name})> files) {
    final backups = files.where((f) => isBackupFileName(f.name)).toList();
    String? keepId;
    for (final f in backups) {
      if (f.name == backupFileName) {
        keepId = f.id;
        break;
      }
    }
    return (
      keepId: keepId,
      deleteIds: [for (final f in backups) if (f.id != keepId) f.id],
    );
  }

  /// Uploads [json] as THE Drive backup: updates the fixed-name file
  /// in place when it exists, creates it otherwise, then deletes
  /// every other backup-pattern file so the folder always holds
  /// exactly one current backup.
  Future<void> _uploadSingleBackup(String json) async {
    final client = await _googleSignIn.authenticatedClient();
    if (client == null) {
      throw StateError('Could not create an authenticated Google client.');
    }
    try {
      final api = drive.DriveApi(client);
      final folderId = await _findOrCreateFolder(api);
      final list = await api.files.list(
        q: "'$folderId' in parents and trashed = false and name contains '.json'",
        spaces: 'drive',
        orderBy: 'createdTime desc',
        $fields: 'files(id, name)',
      );
      final files = (list.files ?? const <drive.File>[])
          .where((f) => f.id != null)
          .map((f) => (id: f.id!, name: f.name ?? ''))
          .toList();
      final plan = planBackupRotation(files);
      final bytes = Uint8List.fromList(utf8.encode(json));
      final media = drive.Media(Stream.value(bytes), bytes.length,
          contentType: 'application/json');
      if (plan.keepId != null) {
        await api.files.update(drive.File(), plan.keepId!, uploadMedia: media);
      } else {
        final file = drive.File()
          ..name = backupFileName
          ..parents = [folderId]
          ..mimeType = 'application/json';
        await api.files.create(file, uploadMedia: media);
      }
      for (final id in plan.deleteIds) {
        try {
          await api.files.delete(id);
        } catch (_) {
          // Cleanup is best-effort: the next sync retries the plan.
        }
      }
    } finally {
      client.close();
    }
  }

  /// Lists available JSON backups stored in the Drive folder.
  Future<List<drive.File>> listBackups() async {
    if (currentAccount == null) {
      final silent = await _googleSignIn.signInSilently();
      if (silent == null) return [];
    }
    final client = await _googleSignIn.authenticatedClient();
    if (client == null) return [];
    try {
      final api = drive.DriveApi(client);
      final folderId = await _findOrCreateFolder(api);
      final list = await api.files.list(
        q: "'$folderId' in parents and trashed = false and name contains '.json'",
        spaces: 'drive',
        orderBy: 'createdTime desc',
        $fields: 'files(id, name, createdTime, size)',
      );
      return list.files ?? [];
    } catch (e) {
      debugPrint('Error listing Drive backups: $e');
      return [];
    } finally {
      client.close();
    }
  }

  /// Downloads content of a Drive file by [fileId].
  Future<String> downloadFile(String fileId) async {
    if (currentAccount == null) await signIn();
    final client = await _googleSignIn.authenticatedClient();
    if (client == null) throw StateError('Not authenticated');
    try {
      final api = drive.DriveApi(client);
      final drive.Media media = await api.files.get(
        fileId,
        downloadOptions: drive.DownloadOptions.fullMedia,
      ) as drive.Media;
      final bytes = <int>[];
      await for (final chunk in media.stream) {
        bytes.addAll(chunk);
      }
      return utf8.decode(bytes);
    } finally {
      client.close();
    }
  }

  /// Immediate backup (owner's rule: an entry must reach Drive at
  /// once, on its own — the per-entry sync in AppProvider calls this
  /// after every change). Uploads the CURRENT full
  /// database JSON under today's backup file name — the file is
  /// overwritten through the day, so Drive always holds the newest
  /// state. Returns false when Drive is not connected.
  Future<bool> uploadCurrentBackupNow() async {
    try {
      if (currentAccount == null) {
        final silent = await _googleSignIn.signInSilently();
        if (silent == null) return false;
      }
      final prefs = await SharedPreferences.getInstance();
      final todayStr = DateFormat('yyyy-MM-dd').format(DateTime.now());
      final json = await DatabaseHelper.instance.exportJson();
      await _uploadSingleBackup(json);
      await prefs.setString('last_auto_drive_backup_date', todayStr);
      await prefs.setString(
          'last_auto_drive_backup_time', DateTime.now().toIso8601String());
      await prefs.setString('drive_backup_status', 'ok');
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Uploads an attachment photo into the app folder under a
  /// deterministic [remoteName]. If a file with that name and the same
  /// size already exists there, its id is reused instead of uploading a
  /// duplicate. Returns the Drive file id, or null when Drive is not
  /// signed in — silent sign-in only, never prompts from a background
  /// sync.
  Future<String?> uploadAttachment(File file, String remoteName) async {
    if (currentAccount == null) {
      final silent = await _googleSignIn.signInSilently();
      if (silent == null) return null;
    }
    final client = await _googleSignIn.authenticatedClient();
    if (client == null) return null;
    try {
      final api = drive.DriveApi(client);
      final folderId = await _findOrCreateFolder(api);
      final size = await file.length();
      final escaped = remoteName.replaceAll("'", r"\'");
      final existing = await api.files.list(
        q: "'$folderId' in parents and trashed = false and name = '$escaped'",
        spaces: 'drive',
        $fields: 'files(id, size)',
      );
      for (final f in existing.files ?? const <drive.File>[]) {
        if ((int.tryParse(f.size ?? '') ?? -1) == size && f.id != null) {
          return f.id;
        }
      }
      final bytes = await file.readAsBytes();
      final media = drive.Media(Stream.value(bytes), bytes.length);
      final meta = drive.File()
        ..name = remoteName
        ..parents = [folderId];
      final created = await api.files.create(meta, uploadMedia: media);
      return created.id;
    } finally {
      client.close();
    }
  }

  /// Downloads a Drive file's raw bytes (used for attachment photos).
  Future<Uint8List?> downloadBytes(String fileId) async {
    if (currentAccount == null) {
      final silent = await _googleSignIn.signInSilently();
      if (silent == null) return null;
    }
    final client = await _googleSignIn.authenticatedClient();
    if (client == null) return null;
    try {
      final api = drive.DriveApi(client);
      final media = await api.files.get(
        fileId,
        downloadOptions: drive.DownloadOptions.fullMedia,
      ) as drive.Media;
      final chunks = <int>[];
      await for (final c in media.stream) {
        chunks.addAll(c);
      }
      return Uint8List.fromList(chunks);
    } finally {
      client.close();
    }
  }

  /// Restore test: downloads the newest Drive backup and verifies it is
  /// a complete, readable Namat Oil Mill backup (app marker present and
  /// row counts readable) WITHOUT touching the live data. Returns a
  /// summary map, or throws when no valid backup exists.
  Future<Map<String, dynamic>> verifyLatestBackup() async {
    final files = await listBackups();
    if (files.isEmpty) throw StateError('no-backup');
    final latest = files.first;
    final content = await downloadFile(latest.id!);
    final data = jsonDecode(content) as Map<String, dynamic>;
    if (data['app'] != 'namat_oil_mill') throw StateError('bad-file');
    var rows = 0;
    var tables = 0;
    for (final e in data.entries) {
      if (e.key == 'app' || e.key == 'version') continue;
      if (e.value is List) {
        tables++;
        rows += (e.value as List).length;
      }
    }
    return {
      'file': latest.name ?? '',
      'rows': rows,
      'tables': tables,
      'sizeKb': ((int.tryParse(latest.size ?? '') ?? 0) / 1024).round(),
    };
  }

  /// Finds the app folder by name, creating it when absent.
  Future<String> _findOrCreateFolder(drive.DriveApi api) async {
    final result = await api.files.list(
      q: "name = '$folderName' and "
          "mimeType = 'application/vnd.google-apps.folder' and "
          'trashed = false',
      spaces: 'drive',
      $fields: 'files(id, name)',
    );
    final existing = result.files;
    if (existing != null && existing.isNotEmpty && existing.first.id != null) {
      return existing.first.id!;
    }
    final folder = drive.File()
      ..name = folderName
      ..mimeType = 'application/vnd.google-apps.folder';
    final created = await api.files.create(folder);
    final id = created.id;
    if (id == null) {
      throw StateError('Drive folder creation finished without an id.');
    }
    return id;
  }
}
