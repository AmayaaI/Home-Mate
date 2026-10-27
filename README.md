# HomeMate

HomeMate is an iOS app for keeping track of everyday household tasks, bills, expenses and events. You can use it offline for your own records, or sign in to share records and chat with family members.

The app is built with SwiftUI and uses MVVM. It stores personal records with Core Data and uses Firebase Authentication and Firestore for account and family features. Receipt scanning uses Apple's Vision framework, and expense suggestions run on the device with Core ML.

## Getting started

You'll need a Mac with Xcode and an iPhone or simulator running iOS 17 or later. The iOS app has no external package dependencies.

1. Open `HomeMate.xcodeproj` in Xcode.
2. Select the **HomeMate** scheme and an iPhone or iPad simulator.
3. Build and run the app.
4. Sign in, or choose **Use offline household** to try it without an account.

To run on a physical device, choose your development team for both the **HomeMate** and **HomeMateWidgets** targets. Both targets use the App Group `group.com.homemate.app.shared`, which needs to be enabled under Signing & Capabilities and registered with your team.

## What's included

- Household tasks, bills, expenses and calendar events
- Receipt scanning and expense category suggestions
- Spending summaries and experimental forecasts
- Family invitations, shared records and text chat
- Private notes and app locking
- Apple Calendar export and a Home Screen widget

Personal records are stored locally for each account. Cloud backup and restore are actions you choose in the app. Family invitations appear in the app, and accepting one requires the invited email address to be verified. Invitation emails are not sent automatically.

Private notes, profile photos and voice attachments stay on the device. **Remember Me** saves a refresh token in Keychain; it does not save the password.

## Firebase setup

To connect your own Firebase project:

1. Enable Email/Password sign-in in Firebase Authentication.
2. Create the default Cloud Firestore database.
3. Register an iOS app with the bundle ID `com.homemate.app` and download `GoogleService-Info.plist`.
4. Install Node.js and Java 21+, then run:

```sh
cd Backend
npm ci
npm run configure -- /absolute/path/to/GoogleService-Info.plist
```

The configure script updates `HomeMate/Info.plist` and `.firebaserc`. Rebuild the app after changing the configuration. Keep downloaded configuration files and service-account credentials out of Git.

From the `Backend` folder, run the Firebase tests with:

```sh
npm test
```

These tests use local Auth and Firestore emulators with the `demo-homemate` project. To deploy the rules and indexes to your own project, replace `YOUR_PROJECT_ID` below:

```sh
npx firebase login
npx firebase deploy --config ../firebase.json --project YOUR_PROJECT_ID --only firestore:rules,firestore:indexes
```

## Project folders

| Folder | Contents |
| --- | --- |
| `HomeMate/` | App screens, ViewModels, models, services and local storage |
| `HomeMate/MLModels/` | Core ML models bundled with the app |
| `HomeMateShared/` | Activity data shared with the widget |
| `HomeMateWidgets/` | Home Screen widget extension |
| `Backend/` | Firebase setup script and emulator tests |
| `Scripts/` | Verification scripts and model training tools |
| `ML/Data/` | Sample datasets used to train and check the models |

Firestore rules and indexes are in `firestore.rules` and `firestore.indexes.json` at the project root.

## Build and checks

Run the following from the project root. The first command builds the simulator app; the others check the ViewModels and widget data.

```sh
xcodebuild -project HomeMate.xcodeproj -scheme HomeMate -sdk iphonesimulator -configuration Debug -derivedDataPath /tmp/HomeMateBuild CODE_SIGNING_ALLOWED=NO build
Scripts/verify_mvvm.sh
swiftc -module-cache-path /tmp/HomeMateWidgetModuleCache HomeMateShared/HomeWidgetSnapshot.swift Scripts/verify_widget.swift -o /tmp/HomeMateWidgetCheck
/tmp/HomeMateWidgetCheck
```

Additional isolated checks use temporary databases or mocked network responses:

```sh
swiftc HomeMate/Models/Models.swift HomeMate/Repositories/HouseholdStore.swift HomeMate/Services/ExpenseML.swift Scripts/verify_store.swift -o /tmp/HomeMateStoreCheck
/tmp/HomeMateStoreCheck

swiftc HomeMate/Models/Models.swift HomeMate/Services/CloudAccount.swift HomeMate/Services/FirebaseHouseholdAPI.swift Scripts/verify_login.swift -o /tmp/HomeMateLoginCheck
/tmp/HomeMateLoginCheck

swiftc HomeMate/Models/Models.swift HomeMate/Repositories/HouseholdStore.swift HomeMate/Services/ExpenseML.swift HomeMate/Services/CloudAccount.swift HomeMate/Services/FirebaseHouseholdAPI.swift HomeMate/Models/FamilyModels.swift HomeMate/Services/FamilyAPI.swift Scripts/verify_family.swift -o /tmp/HomeMateFamilyCheck
/tmp/HomeMateFamilyCheck

swiftc HomeMate/Models/Models.swift HomeMate/Services/ExpenseML.swift Scripts/verify_models.swift -o /tmp/HomeMateMLCheck
/tmp/HomeMateMLCheck /tmp/HomeMateBuild/Build/Products/Debug-iphonesimulator/HomeMate.app
```

Camera scanning, notifications, Face ID and live Firebase features also need manual testing. For Face ID in the simulator, enable **Features → Face ID → Enrolled**, then choose **Matching Face** when the app asks you to authenticate.

### Calendar and widget

To try Calendar export, create an activity with type **Events**, enter a title and start time, and tap **Add to Apple Calendar**. Choose a calendar in Apple's editor and save it. Save the activity in HomeMate too if you want it in both apps. The two copies are separate, so later edits and deletions won't sync.

To try the widget, save an incomplete task, bill or event, then add the HomeMate widget from the Home Screen. Small and medium sizes are available. Updates may take a moment because WidgetKit controls refresh timing. The widget reads local data, so open HomeMate first to refresh cloud records. Signing out clears that account's widget data.

## Expense models

The app includes two Core ML models:

- `ExpenseClassifier.mlmodel` suggests one of six categories for an English expense description.
- `ExpenseForecast.mlmodel` estimates a spending ratio using the last three completed months. Each month needs a positive spending total.

Both run on the device. They were trained with sample expense descriptions and simulated spending histories, so the suggestions and forecasts are experimental. Editing a record does not retrain the models. Changing the currency only changes how amounts are displayed; it does not convert them.

To rebuild the datasets and train the models on a Mac with Create ML:

```sh
python3 Scripts/prepare_ml_data.py
swift Scripts/train_models.swift
```

These commands replace the files in `ML/Data/` and both bundled models. Training also generates evaluation reports under `ML/Reports/`. If you use your own data, keep separate training, validation and test sets.

## Automatic account sync across devices

Signed-in accounts automatically sync profile/onboarding, all private tasks, bills, expenses, maintenance and events (including completion/reminders/location), budgets, notices, private notes/reactions, photos, voice recordings and appearance. Shared family records/chat continue using the existing membership-protected Firebase paths. Face ID, OS permissions and aggregate ML diagnostics remain device-local. Guest data stays separate.

The updated app must run online on the original device to upload existing local data before it can appear on another device. Both devices need this build. Account data loads before onboarding. Failed syncs display a retry banner; local edits survive restart and retry after saves and every 30 seconds while active.

Private snapshots use `users/{uid}/sync/state` and immutable, SHA-256-verified `users/{uid}/syncChunks/{hash}` documents. Attachments are included, split into 450 KB chunks so they do not exceed Firestore's document limit. The current implementation supports up to 57.6 MB of encoded account data; larger accounts show an explicit error without deleting local data. Unreferenced immutable chunks are retained, so storage usage may exceed the current snapshot size. Deploy the rules before using the build.

A server update-time precondition prevents concurrent manifest overwrites. A persisted baseline merges local additions/edits/deletions with remote changes; unrelated records survive, while simultaneous changes to the same record use the later successful local edit. Profile/preferences merge by top-level field. Edits made during transfer stay pending. Passwords and session tokens are never uploaded in snapshots.

The older manual records backup/cloud-record controls remain available separately; they do not represent the automatic account-sync status. Existing profile-only documents are imported when no account snapshot exists. Historical manual record backups can still be restored explicitly.
