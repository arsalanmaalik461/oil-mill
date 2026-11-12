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
      DatabaseHelper.contactNameKey('kashif   PUNJAB'): '03119998887',
      DatabaseHelper.contactNameKey('Rehan'): '03999999999',
      DatabaseHelper.contactNameKey('m asim palcha'): '03221114445',
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
  });
}
