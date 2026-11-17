import 'package:flutter_test/flutter_test.dart';
import 'package:oilmill/services/firebase_service.dart';

/// Delta sync hashes: a row is re-uploaded only when its content
/// hash changes, and a whole table is skipped when its combined
/// hash matches the last successful sync. These hashes are the
/// mechanism that keeps Firestore writes within the free quota.
void main() {
  group('rowSyncHash', () {
    test('is a 16-char lowercase hex string', () {
      final h = FirebaseService.rowSyncHash({'id': 1, 'name': 'x'});
      expect(h, matches(RegExp(r'^[0-9a-f]{16}$')));
    });

    test('is stable across key order', () {
      final a = FirebaseService.rowSyncHash(
          {'id': 7, 'name': 'Nadeem', 'balance': 500, 'phone': '0300'});
      final b = FirebaseService.rowSyncHash(
          {'phone': '0300', 'balance': 500, 'name': 'Nadeem', 'id': 7});
      expect(a, b);
    });

    test('changes when a value changes', () {
      final a = FirebaseService.rowSyncHash({'id': 7, 'balance': 500});
      final b = FirebaseService.rowSyncHash({'id': 7, 'balance': 501});
      expect(a, isNot(b));
    });

    test('changes when a key is added or removed', () {
      final a = FirebaseService.rowSyncHash({'id': 7, 'name': 'x'});
      final b = FirebaseService.rowSyncHash({'id': 7});
      expect(a, isNot(b));
    });

    test('ignores _sync_hash and attachment_drive_id', () {
      final plain = FirebaseService.rowSyncHash({'id': 7, 'name': 'x'});
      final decorated = FirebaseService.rowSyncHash({
        'id': 7,
        'name': 'x',
        '_sync_hash': '0123456789abcdef',
        'attachment_drive_id': 'drive-file-1',
      });
      expect(decorated, plain);
    });

    test('treats an integral double like the matching int', () {
      final asInt = FirebaseService.rowSyncHash({'id': 7, 'qty': 5});
      final asDouble = FirebaseService.rowSyncHash({'id': 7, 'qty': 5.0});
      expect(asDouble, asInt);
    });

    test('distinguishes a fractional double from an int', () {
      final asInt = FirebaseService.rowSyncHash({'id': 7, 'qty': 5});
      final asDouble = FirebaseService.rowSyncHash({'id': 7, 'qty': 5.5});
      expect(asDouble, isNot(asInt));
    });

    test('handles nulls and nested values deterministically', () {
      final a = FirebaseService.rowSyncHash({
        'id': 1,
        'note': null,
        'tags': ['a', 'b'],
        'meta': {'x': 1, 'y': true},
      });
      final b = FirebaseService.rowSyncHash({
        'meta': {'y': true, 'x': 1},
        'tags': ['a', 'b'],
        'note': null,
        'id': 1,
      });
      expect(a, b);
      final c = FirebaseService.rowSyncHash({
        'id': 1,
        'note': null,
        'tags': ['a', 'c'],
        'meta': {'x': 1, 'y': true},
      });
      expect(c, isNot(a));
    });
  });

  group('tableSyncHash', () {
    test('is order independent', () {
      final a = FirebaseService.tableSyncHash({'1': 'aaa', '2': 'bbb'});
      final b = FirebaseService.tableSyncHash({'2': 'bbb', '1': 'aaa'});
      expect(a, b);
    });

    test('changes when any row hash changes', () {
      final a = FirebaseService.tableSyncHash({'1': 'aaa', '2': 'bbb'});
      final b = FirebaseService.tableSyncHash({'1': 'aaa', '2': 'bbc'});
      expect(a, isNot(b));
    });

    test('changes when a row is added or removed', () {
      final a = FirebaseService.tableSyncHash({'1': 'aaa'});
      final b = FirebaseService.tableSyncHash({'1': 'aaa', '2': 'bbb'});
      expect(a, isNot(b));
      expect(FirebaseService.tableSyncHash(const {}), isNot(a));
    });
  });
}
