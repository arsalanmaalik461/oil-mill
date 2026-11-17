import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:oilmill/db/database_helper.dart';
import 'package:oilmill/models/models.dart';

/// Contacts auto-fill (owner's request): imported statement parties
/// arrive with NO phone numbers — matching phone contacts by name
/// fills them in, without ever overwriting an existing number.
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final db = DatabaseHelper.instance;

  setUpAll(() async {
    final path = '${await getDatabasesPath()}/namat_oil_mill.db';
    await databaseFactoryFfi.deleteDatabase(path);
    await db.db;
  });
  tearDownAll(() async => db.close());

  test('name key normalization', () {
    expect(DatabaseHelper.contactNameKey('  Kashif   Punjab '),
        DatabaseHelper.contactNameKey('kashif punjab'));
    expect(DatabaseHelper.contactNameKey('M. Asim Palcha'),
        DatabaseHelper.contactNameKey('m asim palcha'));
  });

  test('fills only empty phones, matched by normalized name', () async {
    final day = DateTime(2026, 11, 6, 12);
    final kashif = await db.insertParty(Party(
        businessId: 1, type: 'customer', name: 'Kashif Punjab', phone: ''));
    final rehan = await db.insertParty(Party(
        businessId: 1,
        type: 'customer',
        name: 'Rehan',
        phone: '03001112223'));
    await db.insertParty(Party(
        businessId: 1, type: 'customer', name: 'M Asim Palcha', phone: ''));

    await db.insertLedgerEntry(PartyTransaction(
        partyId: kashif, type: 'udhaar', amount: 100, dateTime: day));
    expect(await db.countPartyTransactions(kashif), 1);
    expect(await db.countPartyTransactions(rehan), 0);

    final filled = await db.fillPartyPhonesFromContacts(1, {
      DatabaseHelper.contactNameKey('kashif   PUNJAB'): {'03119998887'},
      DatabaseHelper.contactNameKey('Rehan'): {'03999999999'},
      DatabaseHelper.contactNameKey('m asim palcha'): {'03221114445'},
    });
    expect(filled, 2, reason: 'Kashif + Asim filled, Rehan untouched');

    final parties = await db.getParties(1);
    String phoneOf(String name) =>
        parties.firstWhere((x) => x.name == name).phone;
    expect(phoneOf('Kashif Punjab'), '03119998887');
    expect(phoneOf('M Asim Palcha'), '03221114445');
    expect(phoneOf('Rehan'), '03001112223',
        reason: 'existing number never overwritten');
    expect(await db.getPartiesMissingPhone(1), isEmpty);

    // The WhatsApp Reminders path itself: the due list drops parties
    // whose phone is empty, so a filled party that owes money must
    // appear there WITH its new number, ready to send to.
    final due = await db.getPartiesDueForReminder(1);
    final dueKashif = due.where((x) => x.name == 'Kashif Punjab').toList();
    expect(dueKashif, hasLength(1),
        reason: 'filled + owing party is due for a reminder');
    expect(dueKashif.single.phone, '03119998887');
  });

  group('contact matching tiers (same-phone fill failures)', () {
    test('contactNameKeys covers display name AND name parts', () {
      final keys = DatabaseHelper.contactNameKeys(
          displayName: 'Punjab, Kashif', first: 'Kashif', last: 'Punjab');
      // The party typed as 'Kashif Punjab' must find this contact even
      // though its displayName is composed the other way round.
      expect(keys, contains(DatabaseHelper.contactNameKey('Kashif Punjab')));
      expect(keys, contains(DatabaseHelper.contactNameKey('Punjab, Kashif')));
    });

    test('exact, reordered and extra-word matches resolve', () {
      final idx = <String, Set<String>>{
        'kashif punjab': {'03110000001'},
        'asim palcha': {'03220000002'},
      };
      expect(DatabaseHelper.resolveContactPhone('Kashif Punjab', idx),
          '03110000001');
      expect(DatabaseHelper.resolveContactPhone('Punjab Kashif', idx),
          '03110000001',
          reason: 'same words, any order');
      expect(DatabaseHelper.resolveContactPhone('Asim Palcha Gujrat', idx),
          '03220000002',
          reason: 'extra word on the party side');
      expect(DatabaseHelper.resolveContactPhone('Asim', idx), '03220000002',
          reason: 'extra word on the contact side');
      expect(DatabaseHelper.resolveContactPhone('Nobody Here', idx), isNull);
    });

    test('two numbers under one name surface as a choice, never a guess',
        () {
      final idx = <String, Set<String>>{
        'kashif punjab': {'03110000001', '03220000009'},
      };
      expect(DatabaseHelper.contactCandidatesFor('Kashif Punjab', idx),
          {'03110000001', '03220000009'},
          reason: 'both numbers are reported so the user can pick');
      expect(DatabaseHelper.resolveContactPhone('Kashif Punjab', idx),
          isNull,
          reason: 'no silent pick between two numbers');
    });

    test('ambiguous subset matches stay unresolved', () {
      final idx = <String, Set<String>>{
        'kashif punjab': {'03110000001'},
        'kashif lahore': {'03220000002'},
      };
      expect(DatabaseHelper.contactCandidatesFor('Kashif', idx),
          {'03110000001', '03220000002'});
      expect(DatabaseHelper.resolveContactPhone('Kashif', idx), isNull);
    });

    test('exact match wins over a reordered twin', () {
      final idx = <String, Set<String>>{
        'kashif punjab': {'03110000001'},
        'punjab kashif': {'03990000000'},
      };
      expect(DatabaseHelper.resolveContactPhone('Kashif Punjab', idx),
          '03110000001');
    });
  });

  test('fill uses word-order matching; two-number parties stay empty',
      () async {
    final p1 = await db.insertParty(Party(
        businessId: 3, type: 'customer', name: 'Punjab Kashif', phone: ''));
    await db.insertParty(Party(
        businessId: 3, type: 'customer', name: 'Do Number Wala', phone: ''));
    final filled = await db.fillPartyPhonesFromContacts(3, {
      'kashif punjab': {'03110000001'},
      'do number wala': {'03110000002', '03220000003'},
    });
    expect(filled, 1, reason: 'only the unambiguous party is filled');
    final parties = await db.getParties(3);
    expect(parties.firstWhere((x) => x.id == p1).phone, '03110000001');
    expect(parties.firstWhere((x) => x.name == 'Do Number Wala').phone, '',
        reason: 'two-number contact is left for the user to pick');
    // And the manual path the report points to: setPartyPhone.
    final twoNum = parties.firstWhere((x) => x.name == 'Do Number Wala');
    await db.setPartyPhone(twoNum.id!, '03220000003');
    final after = await db.getParties(3);
    expect(after.firstWhere((x) => x.name == 'Do Number Wala').phone,
        '03220000003');
  });
}
