# Namat Oil Mill

**Package:** `com.arsu.oilmill`  
**Version:** 1.0.0+1  
**Platform:** Android (Flutter)

Namat Oil Mill is a complete **offline business khata (ledger) app** built for an oil mill / small business owner. It replaces the paper register for day-to-day business: customer and supplier udhaar, daily cash, stock, bills, staff attendance and salary, bank accounts, expenses and mobile-wallet money — all in one app, on the phone, with **no internet required**.

The design follows a familiar Pakistani khata-app layout: orange-red theme, **green = money in, red = money out**, and bottom navigation **Home • Money • More**.

---

## Features — 12 Modules

- [x] **1. Party Ledger (Customer & Supplier Management)** — Unlimited customers and suppliers, udhaar dena/lena, Jama (credit) and Wasool (debit) entries, opening balance, full transaction history, customer-wise and supplier-wise balances, ledger PDF download, WhatsApp ledger sharing, SMS payment reminders.
- [x] **2. Cash Book** — Cash In / Cash Out entries, daily cash balance, cash in hand, income and expense records, party-wise entries, bill photo attachment, cash history, PDF export.
- [x] **3. Stock Book / Inventory** — Unlimited products/items with name and unit, Stock In and Stock Out, purchase quantity and rate, supplier selection, bill number, date & time, camera/gallery bill attachment, low-stock view, stock reports. Creating a bill automatically deducts stock.
- [x] **4. Bill Book / Invoices** — Multi-item bills with quantity and rate, customer selection, automatic stock-out and customer-ledger posting on bill creation, paid/pending status, digital invoice PDF, WhatsApp bill sharing.
- [x] **5. Staff Book** — Employee records, daily attendance (present / absent / half day, mark-all-present), monthly attendance summary, salary, overtime, bonus and advance payments, employee-wise payment history.
- [x] **6. Bank Book** — Multiple bank accounts, opening balance, bank transactions (in/out), bank-wise balance tracking.
- [x] **7. Expense Book** — Business expense tracking with categories (fuel, labour, rent, maintenance, etc.), cash/bank account selection, expense history and category totals.
- [x] **8. DigiCash / Digital Payments** — Wallet channels for DigiCash, JazzCash, Easypaisa and Bank; Money In / Money Out, Request Money, Send Money, mobile recharge and package records with commission tracking.
- [x] **9. Collection & Payment Reminders** — Outstanding-balance list, per-party due date, one-tap WhatsApp and SMS payment reminders, call shortcut.
- [x] **10. Business Reports & Analytics (PDF)** — Daily and monthly summaries (sales, expenses, net cash flow), party outstanding report, cash report and stock report — all exportable as PDF and shareable on WhatsApp.
- [x] **11. Business & Account Management** — Multiple businesses on one device with one-tap switching, business profile (name, owner, phone, address), recycle bin for deleted parties, items, bills, staff and bank accounts (restore or delete forever).
- [x] **12. Security & Backup** — PIN lock with fingerprint unlock, full JSON backup export and restore (Settings), offline-first data with everything stored on the device.

**Languages:** Urdu (اردو, full RTL layout) and English, switchable in Settings / More tab.

---

## Tech Stack

| Layer | Technology |
|---|---|
| Framework | Flutter 3.47.9 (Dart) |
| Local database | SQLite via `sqflite` — 15 tables, fully offline |
| State management | `provider` |
| PDF generation | `pdf` + `printing` (invoices, ledgers, reports) |
| Sharing & links | `share_plus`, `url_launcher` (WhatsApp / SMS deep links) |
| Security | `local_auth` (fingerprint), `crypto` (SHA-256 PIN hash) |
| Files & photos | `file_picker`, `image_picker`, `path_provider` |
| Settings storage | `shared_preferences` |

**Android config:** applicationId `com.arsu.oilmill` · minSdk 24 (Android 7.0+) · targetSdk / compileSdk 36 · Java/Kotlin target 17 · launcher icons generated with `flutter_launcher_icons` (adaptive icon, background `#F05623`).

---

## Build

Requirements: Flutter SDK 3.47+, JDK 17, Android SDK 35/36.

```bash
flutter pub get
flutter build apk --release
```

The APK is produced at:

```
build/app/outputs/flutter-apk/app-release.apk
```

Launcher icons (after replacing `assets/icon/icon.png`, 1024×1024):

```bash
dart run flutter_launcher_icons
```

> **Sandbox note:** the Gradle build daemon talks to the Gradle client over a **loopback (127.0.0.1) TCP socket**. In restricted sandboxes where direct/other TCP is denied, the build fails with *"Could not dispatch a message to the daemon"* even though all code is fine — allow loopback/other TCP for the build environment (e.g. in Muse: Settings → Permissions → Direct network protocols → `other_tcp` → Ask).
>
> **Signing note:** the release build type currently uses the debug signing config (Flutter template default). Add a production keystore before publishing to Google Play.

---

## Data & Privacy

- **All data stays on the device** in a local SQLite database (`namat_oil_mill.db`). No account, no server, no internet needed for daily use.
- **Backup / restore:** Settings → Backup exports the complete database as a single JSON file that can be shared or saved anywhere; Settings → Restore imports it back (this replaces current data, with a confirmation prompt).
- Bill photos picked from camera/gallery are copied into the app's private storage.
- The PIN is never stored in plain text — only its SHA-256 hash is kept in app preferences.

---

## Colour Scheme

| Use | Colour |
|---|---|
| Primary (headers, buttons) | Orange-red `#F05623` → `#EE4023` gradient |
| Money in / you will get | Green `#1DA851` |
| Money out / you will give | Red `#E03131` |
| Module icons | Amber `#F5A623` |

---

## Google Drive setup (one-time)

Settings → **Google Drive → Connect Google** signs the user in with Google and uploads the full ledger PDF (all parties) into a **"Namat Oil Mill"** folder in their own Google Drive. After connecting, the same screen offers **Upload Ledger PDF to Drive** (rebuild + upload on tap) and **Disconnect**.

This needs a **one-time setup by the app owner** — Google sign-in cannot work without it:

1. Create a **Firebase project** (or use Google Cloud Console directly) at [console.firebase.google.com](https://console.firebase.google.com).
2. Add an **Android app** to the project with package name **`com.arsu.oilmill`**.
3. Add the **SHA-1 fingerprint** of your signing keystore to that Android app:
   - Debug keystore: `keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey` (password `android`).
   - Release keystore: use the SHA-1 of the keystore you sign the release APK/AAB with. Add **both** SHA-1s if you test debug builds and ship release builds.
4. Download **`google-services.json`** from the Firebase project settings and place it in **`android/app/`**.
5. In Google Cloud Console (same project), **enable the Google Drive API** (APIs & Services → Library → Google Drive API → Enable).
6. If the OAuth consent screen is in **Testing** mode, add the Google account(s) that will use the feature as **test users** (APIs & Services → OAuth consent screen → Test users). Otherwise sign-in fails for everyone not listed.

> **Without this one-time setup the Connect button cannot sign in** — the app shows "Google sign-in failed" together with the setup note. Everything else in the app keeps working fully offline, exactly as before; Google Drive is an optional backup destination, never a requirement.
