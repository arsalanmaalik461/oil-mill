import 'backup_notifier.dart';
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

/// Google Drive backup for ledger PDFs & automated daily database JSON backups.
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

  Timer? _periodicBackupTimer;

  /// The underlying [GoogleSignIn] instance (for silent session restore).
  GoogleSignIn get googleSignIn => _googleSignIn;

  /// The currently signed-in account, or null when signed out.
  GoogleSignInAccount? get currentAccount => _googleSignIn.currentUser;

  /// Whether a user is currently signed in.
  Future<bool> isSignedIn() => _googleSignIn.isSignedIn();

  /// Signs in: tries a silent sign-in first (restores an existing
  /// session), then falls back to the interactive flow.
  Future<GoogleSignInAccount?> signIn() async {
    final silent = await _googleSignIn.signInSilently();
    if (silent != null) return silent;
    return _googleSignIn.signIn();
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

  /// Uploads raw JSON string [jsonString] as [fileName] into the Drive folder.
  Future<String> uploadJson(String jsonString, String fileName) async {
    final bytes = Uint8List.fromList(utf8.encode(jsonString));
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
          contentType: 'application/json');
      final file = drive.File()
        ..name = fileName
        ..parents = [folderId]
        ..mimeType = 'application/json';
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

  /// Automatically executes daily midnight backup to Google Drive if due.
  /// Runs silently in the background without disturbing the user.
  Future<bool> runAutoBackupIfDue() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      final enabled = prefs.getBool('auto_drive_backup_enabled') ?? true;
      if (!enabled) return false;

      // Ensure signed in silently. Not being signed in is NOT a failure —
      // the backup simply is not connected yet.
      if (currentAccount == null) {
        final silent = await _googleSignIn.signInSilently();
        if (silent == null) return false;
      }

      final todayStr = DateFormat('yyyy-MM-dd').format(DateTime.now());
      final lastDate = prefs.getString('last_auto_drive_backup_date');
      if (lastDate == todayStr) {
        return false; // Already successfully backed up today
      }

      final json = await DatabaseHelper.instance.exportJson();
      final fileName = 'namat_backup_$todayStr.json';
      await uploadJson(json, fileName);

      await prefs.setString('last_auto_drive_backup_date', todayStr);
      await prefs.setString(
          'last_auto_drive_backup_time', DateTime.now().toIso8601String());
      await prefs.setString('drive_backup_status', 'ok');
      await prefs.remove('drive_backup_error');
      debugPrint('Automated Google Drive daily backup completed: $fileName');
      return true;
    } catch (e) {
      // A real failure (network, quota, export error): record it where
      // Settings can show it, and notify the owner.
      await prefs.setString('drive_backup_status', 'failed');
      await prefs.setString('drive_backup_error', '$e');
      await prefs.setString('drive_backup_last_attempt',
          DateTime.now().toIso8601String());
      debugPrint('Automated Drive backup FAILED: $e');
      await BackupNotifier.instance.showBackupFailed();
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

  /// Starts a periodic background timer (every 30 mins) to check if midnight /
  /// next day has arrived to trigger automated Google Drive backup.
  void startAutoBackupScheduler() {
    _periodicBackupTimer?.cancel();
    runAutoBackupIfDue();
    _periodicBackupTimer = Timer.periodic(const Duration(minutes: 30), (_) {
      runAutoBackupIfDue();
    });
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
