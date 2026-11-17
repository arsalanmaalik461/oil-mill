import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:oilmill/db/database_helper.dart';
import 'package:oilmill/models/models.dart';
import 'package:oilmill/utils/google_drive_service.dart';

/// Requirement 9 — exactly ONE always-current backup file, on Drive
/// and on the phone: the rotation plan (which Drive file is kept and
/// updated in place, which are deleted) and the fixed-name on-device
/// file that every write replaces wholesale.
void main() {
  group('backup file naming', () {
    test('fixed name has no date in it', () {
      expect(GoogleDriveService.backupFileName, 'namat_backup.json');
      expect(DatabaseHelper.localBackupFileName, 'namat_backup.json');
    });

    test('isBackupFileName matches current + legacy, nothing else', () {
      expect(GoogleDriveService.isBackupFileName('namat_backup.json'),
          isTrue);
      expect(
          GoogleDriveService.isBackupFileName('namat_backup_2026-11-17.json'),
          isTrue);
      expect(GoogleDriveService.isBackupFileName('Ledger-X.pdf'), isFalse);
      expect(GoogleDriveService.isBackupFileName('notes.json'), isFalse);
      expect(GoogleDriveService.isBackupFileName('photo.jpg'), isFalse);
    });
  });

  group('planBackupRotation (files given newest first)', () {
    test('empty folder -> create, delete nothing', () {
      final plan = GoogleDriveService.planBackupRotation(const []);
      expect(plan.keepId, isNull);
      expect(plan.deleteIds, isEmpty);
    });

    test('one fixed-name file -> keep it, delete nothing', () {
      final plan = GoogleDriveService.planBackupRotation(const [
        (id: 'a', name: 'namat_backup.json'),
      ]);
      expect(plan.keepId, 'a');
      expect(plan.deleteIds, isEmpty);
    });

    test('fixed file + legacy dated files -> keep fixed, delete dated',
        () {
      final plan = GoogleDriveService.planBackupRotation(const [
        (id: 'a', name: 'namat_backup.json'),
        (id: 'b', name: 'namat_backup_2026-11-17.json'),
        (id: 'c', name: 'namat_backup_2026-11-16.json'),
      ]);
      expect(plan.keepId, 'a');
      expect(plan.deleteIds, ['b', 'c']);
    });

    test('only legacy dated files -> create fixed, delete all dated',
        () {
      final plan = GoogleDriveService.planBackupRotation(const [
        (id: 'b', name: 'namat_backup_2026-11-17.json'),
        (id: 'c', name: 'namat_backup_2026-11-16.json'),
      ]);
      expect(plan.keepId, isNull);
      expect(plan.deleteIds, ['b', 'c']);
    });

    test('duplicate fixed-name files -> keep the newest, delete rest',
        () {
      final plan = GoogleDriveService.planBackupRotation(const [
        (id: 'new', name: 'namat_backup.json'),
        (id: 'old', name: 'namat_backup.json'),
        (id: 'd', name: 'namat_backup_2026-11-15.json'),
      ]);
      expect(plan.keepId, 'new');
      expect(plan.deleteIds, ['old', 'd']);
    });

    test('non-backup files are never touched', () {
      final plan = GoogleDriveService.planBackupRotation(const [
        (id: 'pdf', name: 'Ledger-2026-11-17.pdf'),
        (id: 'a', name: 'namat_backup.json'),
        (id: 'img', name: 'photo.jpg'),
      ]);
      expect(plan.keepId, 'a');
      expect(plan.deleteIds, isEmpty);
    });
  });

  group('on-device backup file', () {
    final db = DatabaseHelper.instance;

    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final dbPath = await getDatabasesPath();
      final file = File('$dbPath/namat_oil_mill.db');
      if (await file.exists()) await file.delete();
    });

    test('one fixed-name file, replaced wholesale on every write',
        () async {
      final dir =
          await Directory.systemTemp.createTemp('namat_backup_test');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final biz = await db.insertBusiness(Business(name: 'Backup Mill'));
      await db.insertParty(
          Party(businessId: biz, type: 'customer', name: 'First Party'));

      final f1 = await db.writeLocalBackupTo(dir);
      expect(f1.path.endsWith('namat_backup.json'), isTrue);
      final j1 = jsonDecode(await f1.readAsString()) as Map<String, dynamic>;
      expect(j1['app'], 'namat_oil_mill');
      expect((j1['parties'] as List).length, 1);

      await db.insertParty(
          Party(businessId: biz, type: 'customer', name: 'Second Party'));
      final f2 = await db.writeLocalBackupTo(dir);
      expect(f2.path, f1.path, reason: 'same single file every time');
      final j2 = jsonDecode(await f2.readAsString()) as Map<String, dynamic>;
      expect((j2['parties'] as List).length, 2,
          reason: 'the new write REPLACES the old content in full');
      final files = dir.listSync().whereType<File>().toList();
      expect(files.length, 1,
          reason: 'exactly one backup file on the phone — no pile-up');
      expect(files.single.path.endsWith('namat_backup.json'), isTrue);
    });
  });
}
