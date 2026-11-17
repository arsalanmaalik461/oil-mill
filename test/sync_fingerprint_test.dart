import 'package:flutter_test/flutter_test.dart';
import 'package:oilmill/services/firebase_service.dart';

/// Cross-device propagation of VALUE-ONLY changes (owner's report):
/// party numbers filled from contacts on one phone never appeared in
/// WhatsApp Reminders on the other phone. The fill itself persists
/// (see contacts_fill_test) — the failure was reconciliation: login
/// sync compared only row COUNTS, and a fill moves no counts, so the
/// second phone never restored the filled rows and its own uploads
/// overwrote them in the cloud. The fix fingerprints the synced
/// content; these tests pin the fingerprint and the login decision
/// built on it.
void main() {
  Map<String, dynamic> exportWith(String kashifPhone) => {
        'app': 'namat_oil_mill',
        'version': 1,
        'businesses': [
          {'id': 1, 'name': 'Nemat Oil Mill'}
        ],
        'parties': [
          {'id': 7, 'business_id': 1, 'name': 'Kashif Punjab', 'phone': kashifPhone},
          {'id': 9, 'business_id': 1, 'name': 'Rehan', 'phone': '03001112223'},
        ],
        'party_transactions': [
          {'id': 3, 'party_id': 7, 'type': 'udhaar', 'amount': 100},
        ],
      };

  group('businessFingerprint', () {
    test('stable across row order and map key order', () {
      final a = FirebaseService.businessFingerprint(exportWith(''));
      final reordered = exportWith('');
      reordered['parties'] =
          (reordered['parties'] as List).reversed.toList();
      final b = FirebaseService.businessFingerprint(reordered);
      expect(b, a);
    });

    test('changes when a phone number is filled in (count unchanged)',
        () {
      final before = FirebaseService.businessFingerprint(exportWith(''));
      final after =
          FirebaseService.businessFingerprint(exportWith('03119998887'));
      expect(after, isNot(before));
    });

    test('ignores cloud-only keys (_sync_hash, attachment_drive_id)',
        () {
      final plain = FirebaseService.businessFingerprint(exportWith(''));
      final cloudShaped = exportWith('');
      (cloudShaped['parties'] as List).first['_sync_hash'] = 'abc123';
      (cloudShaped['parties'] as List).first['attachment_drive_id'] =
          'drive-file-1';
      expect(FirebaseService.businessFingerprint(cloudShaped), plain);
    });
  });

  group('loginSyncDecisionV2 — the filled-numbers scenario', () {
    // Both phones hold the same 3,084 rows; only VALUES differ.
    const rows = 3084;

    test('cloud changed elsewhere, local untouched -> restore', () {
      expect(
        FirebaseService.loginSyncDecisionV2(
          localRows: rows,
          cloudRows: rows,
          localFingerprint: 'fp-before-fill',
          cloudFingerprint: 'fp-after-fill',
          lastSyncedFingerprint: 'fp-before-fill',
        ),
        'restore',
      );
    });

    test('local has unsynced changes of its own -> count rule (upload)',
        () {
      expect(
        FirebaseService.loginSyncDecisionV2(
          localRows: rows,
          cloudRows: rows,
          localFingerprint: 'fp-my-own-edits',
          cloudFingerprint: 'fp-after-fill',
          lastSyncedFingerprint: 'fp-before-fill',
        ),
        'upload',
      );
    });

    test('cloud unchanged since last sync -> count rule', () {
      expect(
        FirebaseService.loginSyncDecisionV2(
          localRows: rows,
          cloudRows: rows,
          localFingerprint: 'fp-same',
          cloudFingerprint: 'fp-same',
          lastSyncedFingerprint: 'fp-same',
        ),
        'upload',
      );
      expect(
        FirebaseService.loginSyncDecisionV2(
          localRows: 3,
          cloudRows: rows,
          localFingerprint: 'fp-same',
          cloudFingerprint: 'fp-same',
          lastSyncedFingerprint: 'fp-same',
        ),
        'restore',
        reason: 'cloud richer still restores via counts',
      );
    });

    test('no fingerprints (older build) -> pure count rule', () {
      expect(
        FirebaseService.loginSyncDecisionV2(
          localRows: 0,
          cloudRows: rows,
          localFingerprint: null,
          cloudFingerprint: null,
          lastSyncedFingerprint: null,
        ),
        'restore',
      );
      expect(
        FirebaseService.loginSyncDecisionV2(
          localRows: rows,
          cloudRows: rows,
          localFingerprint: null,
          cloudFingerprint: null,
          lastSyncedFingerprint: null,
        ),
        'upload',
      );
      expect(
        FirebaseService.loginSyncDecisionV2(
          localRows: 0,
          cloudRows: 0,
          localFingerprint: null,
          cloudFingerprint: null,
          lastSyncedFingerprint: null,
        ),
        'none',
      );
    });
  });
}
