import 'package:flutter_test/flutter_test.dart';
import 'package:oilmill/services/firebase_service.dart';

/// Admin full user edit (Requirement 5): the username is the
/// Firestore doc id and the root of the user's data tree, so a
/// rename is a MOVE. These tests pin the pure planning/validation
/// logic the move is built on — normalization identical to
/// createUser, rename detection, and the validity rules (non-empty,
/// not taken by another user, same name = in-place edit).
void main() {
  group('normalizeUsername', () {
    test('trims and lowercases, exactly like createUser', () {
      expect(FirebaseService.normalizeUsername('  AbC '), 'abc');
      expect(FirebaseService.normalizeUsername('1'), '1');
      expect(FirebaseService.normalizeUsername('   '), '');
    });
  });

  group('isUsernameRename', () {
    test('same name after normalization is NOT a rename', () {
      expect(FirebaseService.isUsernameRename('1', ' 1 '), isFalse);
      expect(FirebaseService.isUsernameRename('abc', 'ABC'), isFalse);
    });
    test('a different name IS a rename', () {
      expect(FirebaseService.isUsernameRename('1', '2'), isTrue);
      expect(FirebaseService.isUsernameRename('abc', 'abd'), isTrue);
    });
  });

  group('validateUsernameChange', () {
    final existing = {'1', '2', 'nadeem'};

    test('empty new username is rejected', () {
      expect(FirebaseService.validateUsernameChange('1', '   ', existing),
          'username-empty');
      expect(FirebaseService.validateUsernameChange('1', '', existing),
          'username-empty');
    });

    test('a name taken by ANOTHER user is rejected', () {
      expect(FirebaseService.validateUsernameChange('1', '2', existing),
          'user-exists');
      expect(FirebaseService.validateUsernameChange('1', ' NADEEM ', existing),
          'user-exists',
          reason: 'normalization applies before the taken check');
    });

    test('keeping the same username is a valid in-place edit', () {
      expect(FirebaseService.validateUsernameChange('1', '1', existing),
          isNull);
      expect(FirebaseService.validateUsernameChange('nadeem', 'Nadeem', existing),
          isNull);
    });

    test('a free new username is valid', () {
      expect(FirebaseService.validateUsernameChange('1', '3', existing),
          isNull);
      expect(FirebaseService.validateUsernameChange('2', 'newname', existing),
          isNull);
    });
  });
}
