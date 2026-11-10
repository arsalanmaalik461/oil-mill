import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oilmill/models/models.dart';
import 'package:oilmill/utils/pdf_service.dart';


/// Regression test for the phone crash "PDF press karne par app band ho
/// jati hai": the pdf package's MultiPage defaults to maxPages = 20, so a
/// statement longer than ~20 pages threw PdfTooBigPageException. With a
/// large imported ledger (3,025 entries) generation must now complete —
/// in a test environment only the platform share call may fail, with a
/// MissingPluginException.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final biz = Business(name: 'Nemat Oil Mill', phone: '03007900963');

  PartyTransaction tx(int id, int partyId, bool gave, double amt, int i) =>
      PartyTransaction(
        id: id,
        partyId: partyId,
        type: gave ? 'udhaar' : 'wasool',
        amount: amt,
        note: 'entry $i',
        dateTime: DateTime(2025, (i % 12) + 1, (i % 28) + 1, 12),
      );

  test('statement PDF with 3025 entries generates beyond 20 pages', () async {
    final parties = [
      Party(id: 1, businessId: 1, type: 'customer', name: 'Shaik Sami'),
      Party(id: 2, businessId: 1, type: 'customer', name: 'Kashif'),
    ];
    final byParty = <int, List<PartyTransaction>>{
      1: [for (var i = 0; i < 2900; i++) tx(i + 1, 1, i.isEven, 100.0 + i, i)],
      2: [for (var i = 0; i < 125; i++) tx(5000 + i, 2, true, 500.0, i)],
    };
    Object? error;
    try {
      await shareStatementPdf(
          business: biz, parties: parties, transactionsByParty: byParty);
    } catch (e) {
      error = e;
    }
    expect(error, isA<MissingPluginException>(),
        reason: 'generation must succeed; only the share plugin is absent');
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('single-party ledger with 1500 entries generates', () async {
    final party = Party(id: 1, businessId: 1, type: 'customer', name: 'Big');
    final txns = [
      for (var i = 0; i < 1500; i++) tx(i + 1, 1, i.isEven, 250.0 + i, i)
    ];
    Object? error;
    try {
      await shareLedgerPdf(
          business: biz, party: party, transactions: txns, balance: 12345);
    } catch (e) {
      error = e;
    }
    expect(error, isA<MissingPluginException>());
  });
}
