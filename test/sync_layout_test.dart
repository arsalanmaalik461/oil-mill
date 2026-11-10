import 'package:flutter_test/flutter_test.dart';
import 'package:oilmill/services/firebase_service.dart';

/// Cloud sync v2 lays every record out as its own Firestore document
/// (app_users/{user}/tables/{table}/rows/{rowId}) so entries are visible
/// in the console and no table can hit the 1 MiB document limit.
void main() {
  test('rowDocId uses the local row id', () {
    expect(FirebaseService.rowDocId({'id': 42, 'name': 'x'}, 0), '42');
    expect(FirebaseService.rowDocId({'id': 7}, 3), '7');
  });

  test('rowDocId falls back to a positional id when the row has none', () {
    expect(FirebaseService.rowDocId({'name': 'x'}, 5), 'x5');
    expect(FirebaseService.rowDocId({'id': null}, 2), 'x2');
  });
}
