import 'package:flutter_test/flutter_test.dart';
import 'package:oilmill/utils/google_drive_service.dart';

/// Google Connect on a second phone (owner's report): the account was
/// connected on phone A, but phone B showed Google as NOT connected.
/// Root cause: the Settings status check gated its silent sign-in
/// behind GoogleSignIn.isSignedIn(), which only reflects the plugin's
/// cached session ON THAT DEVICE — false exactly on a phone that has
/// not signed in yet, so the restore was never attempted there. The
/// fix routes the check through [GoogleDriveService.restoreSession],
/// which always attempts the silent restore (the authorization
/// belongs to the Google account, not to one phone) and never throws
/// or pops interactive UI.
void main() {
  test('restoreSession attempts a silent restore and never throws',
      () async {
    // No platform implementation exists in the test environment, so
    // there is no session to restore: the call must simply report
    // "not connected" (null) instead of throwing, and leave the
    // current account unset.
    final account = await GoogleDriveService.instance.restoreSession();
    expect(account, isNull);
    expect(GoogleDriveService.instance.currentAccount, isNull);
  });

  test('changeAccount never throws and reports the true signed-out '
      'state when no sign-in can complete', () async {
    // Settings' Change Google Account flow: sign out, then the
    // interactive chooser. With no platform implementation the switch
    // cannot complete — it must surface as null (Settings then
    // re-reads the real state), never as a throw, and no account or
    // email may be reported afterwards.
    final account = await GoogleDriveService.instance.changeAccount();
    expect(account, isNull);
    expect(GoogleDriveService.instance.currentAccount, isNull);
    expect(GoogleDriveService.instance.currentAccountEmail, isNull);
  });
}
