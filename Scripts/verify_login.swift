import Foundation

// Test-only in-memory store. No real household or Keychain data is touched.
@MainActor final class HouseholdStore {
    var records: [HouseholdRecord] = []
    var saves = 0
    var scope = "user:demo-user"
    var error: String?
    func save() { saves += 1 }
    func replaceRecords(_ value: [HouseholdRecord], expectedScope: String) -> Bool {
        guard expectedScope == scope, value.allSatisfy({ $0.validationError == nil }) else { return false }
        records = value; save(); return true
    }
}
@MainActor final class MemoryAuthStorage: AuthSessionStorage {
    var value: SavedAuthSession?
    var saves = 0
    var clears = 0
    var failWrites = false
    func load() throws -> SavedAuthSession? { value }
    func save(_ session: SavedAuthSession) throws {
        if failWrites { throw URLError(.cannotWriteToFile) }
        value = session; saves += 1
    }
    func clear() throws {
        if failWrites { throw URLError(.cannotWriteToFile) }
        value = nil; clears += 1
    }
}
final class MockFirebase: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: Any]))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, object) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: object))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
@main struct VerifyLogin {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "HomeMateLoginTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
    static func json(_ request: URLRequest) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: body(request)) as? [String: Any] ?? [:]
    }
    @MainActor static func main() async throws {
        let suite = "HomeMateAuthTests-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockFirebase.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let storage = MemoryAuthStorage()
        let account = CloudAccount(apiKey: "demo-key", projectID: "demo-project", session: session, storage: storage, sessionPreferences: preferences)
        account.email = "  person@example.test  "; account.password = "demo-password"
        MockFirebase.handler = { request in
            try require(request.url?.path.hasSuffix("accounts:signInWithPassword") == true, "Wrong sign-in endpoint")
            let payload = try json(request)
            try require(payload["email"] as? String == "person@example.test", "Email must be trimmed")
            try require(payload["password"] as? String == "demo-password", "Missing password")
            return (200, ["idToken": "demo-id-token", "localId": "demo-user", "refreshToken": "demo-refresh", "email": "person@example.test", "expiresIn": "3600"])
        }
        let loggedIn = await account.authenticate(register: false)
        try require(loggedIn && account.signedIn && account.password.isEmpty, "Sign in or password clearing failed")
        try require(storage.value?.refreshToken == "demo-refresh" && storage.saves == 1, "Remember Me must save a refresh token")
        account.signOut()
        try require(!account.signedIn && storage.value == nil, "Sign out must clear remembered session")

        account.email = "person@example.test"; account.rememberSession = false; account.password = "demo-password"
        let temporary = await account.authenticate(register: false)
        try require(temporary && storage.value == nil, "Unchecked Remember Me must not persist a session")
        account.signOut()
        account.email = "person@example.test"; account.password = "demo-password"
        MockFirebase.handler = { request in
            try require(request.url?.path.hasSuffix("accounts:signUp") == true, "Wrong registration endpoint")
            return (200, ["idToken": "demo-id-token", "localId": "demo-user", "refreshToken": "demo-refresh", "expiresIn": "3600"])
        }
        let registered = await account.authenticate(register: true)
        try require(registered && account.signedIn, "Registration failed")
        account.signOut()

        MockFirebase.handler = { request in
            try require(request.url?.path.hasSuffix("accounts:sendOobCode") == true, "Wrong reset endpoint")
            let payload = try json(request)
            try require(payload["requestType"] as? String == "PASSWORD_RESET" && payload["email"] as? String == "person@example.test", "Wrong reset payload")
            return (200, ["email": "person@example.test"])
        }
        await account.sendPasswordReset(to: " person@example.test ")
        try require(!account.isError && account.message.contains("reset link"), "Reset confirmation missing")

        preferences.set(true, forKey: "authSessionRestoreAllowed.demo-project")
        storage.value = SavedAuthSession(email: "person@example.test", refreshToken: "a+b&c")
        MockFirebase.handler = { request in
            try require(request.url?.host == "securetoken.googleapis.com", "Wrong refresh endpoint")
            let form = String(data: body(request), encoding: .utf8) ?? ""
            try require(form.contains("grant_type=refresh_token") && form.contains("a%2Bb%26c"), "Refresh token was not form-encoded safely")
            return (200, ["id_token": "fresh-id", "user_id": "demo-user", "refresh_token": "rotated-refresh", "expires_in": "3600"])
        }
        let restored = CloudAccount(apiKey: "demo-key", projectID: "demo-project", session: session, storage: storage, sessionPreferences: preferences)
        await restored.restoreSession()
        try require(restored.signedIn && storage.value?.refreshToken == "rotated-refresh", "Restore or refresh-token rotation failed")

        MockFirebase.handler = { request in
            try require(request.httpMethod == "PATCH" && request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-id", "Backup must use refreshed ID token")
            try require(request.url?.path.hasSuffix("households/demo-user") == true, "Backup must belong to the signed-in user")
            return (200, [:])
        }
        await restored.sync(store: HouseholdStore(), restore: false)
        try require(!restored.isError && restored.message.contains("backed up"), "Authenticated backup failed")
        let record = HouseholdRecord(kind: .task, title: "API test")
        let encoded = try FirestoreRecordCodec.encode(record)
        try require(try FirestoreRecordCodec.decode(encoded).id == record.id, "Record codec round trip failed")
        let api = FirebaseHouseholdAPI(account: restored)
        MockFirebase.handler = { request in
            try require(request.value(forHTTPHeaderField: "Authorization") != nil, "Record API needs bearer token")
            try require(request.url!.path.contains("/households/demo-user/records"), "Wrong owner path")
            if request.httpMethod == "PATCH" { try require(try json(request)["fields"] != nil, "Missing typed record"); return (200, encoded) }
            if request.httpMethod == "DELETE" { return (200, [:]) }
            return (200, ["documents": [encoded]])
        }
        try await api.save(record)
        let cloudRecords = try await api.records()
        try require(cloudRecords.count == 1 && cloudRecords[0].id == record.id, "Record list failed")
        try await api.delete(id: record.id)
        print("PASS: typed record codec and authenticated CRUD requests")
        restored.signOut()
        account.email = "person@example.test"; account.password = "wrong-demo-password"
        MockFirebase.handler = { _ in (400, ["error": ["message": "INVALID_LOGIN_CREDENTIALS"]]) }
        let rejected = await account.authenticate(register: false)
        try require(!rejected && !account.signedIn && account.isError && account.message == "The email or password is incorrect.", "Failed sign-in must show a friendly error without authenticating")
        var unexpectedCalls = 0
        MockFirebase.handler = { _ in unexpectedCalls += 1; return (500, [:]) }
        account.email = "not-an-email"; account.password = "password"
        let invalidEmail = await account.authenticate(register: false)
        try require(!invalidEmail && unexpectedCalls == 0, "Invalid login must not contact Firebase")
        account.email = "person@example.test"; account.password = "123"
        let weakPassword = await account.authenticate(register: true)
        try require(!weakPassword && unexpectedCalls == 0 && account.message.contains("6 characters"), "Weak registration passwords must fail locally")
        let unconfigured = CloudAccount(apiKey: "", projectID: "", session: session, storage: MemoryAuthStorage(), sessionPreferences: preferences)
        let result = await unconfigured.authenticate(register: false)
        try require(!result && !unconfigured.signedIn, "Unconfigured projects must not fake authentication")
        try require(unconfigured.isError && unconfigured.message.contains("Firebase configuration is missing"), "Missing setup must explain why login cannot continue")
        let unconfiguredRegistration = await unconfigured.authenticate(register: true)
        try require(!unconfiguredRegistration && !unconfigured.signedIn && unconfigured.isError, "Registration must report missing setup without faking success")
        MockFirebase.handler = { _ in
            throw NSError(domain: "UnexpectedNetworkRequest", code: 1)
        }
        await account.sendPasswordReset(to: "invalid")
        try require(account.isError && account.message == "Enter a valid email address.", "Invalid reset addresses must be rejected before networking")
        // A late authentication response must never undo an explicit sign-out.
        let lateStorage = MemoryAuthStorage()
        let late = CloudAccount(apiKey: "demo-key", projectID: "demo-project", session: session, storage: lateStorage, sessionPreferences: preferences)
        late.email = "person@example.test"; late.password = "demo-password"
        MockFirebase.handler = { _ in
            Thread.sleep(forTimeInterval: 0.1)
            return (200, ["idToken": "late-id", "localId": "demo-user", "refreshToken": "late-refresh", "expiresIn": "3600"])
        }
        let pending = Task { await late.authenticate(register: false) }
        while !late.busy { await Task.yield() }
        late.signOut()
        let lateResult = await pending.value
        try require(!lateResult && !late.signedIn && lateStorage.value == nil, "Late login response must not undo sign-out")
        // A cloud response that finishes after logout must not restore the previous user's records.
        let cloudAccount = CloudAccount(apiKey: "demo-key", projectID: "demo-project", session: session, storage: MemoryAuthStorage(), sessionPreferences: preferences)
        cloudAccount.email = "person@example.test"; cloudAccount.password = "demo-password"
        MockFirebase.handler = { _ in (200, ["idToken":"cloud-token", "localId":"demo-user", "refreshToken":"refresh", "expiresIn":"3600"]) }
        let cloudLogin = await cloudAccount.authenticate(register: false)
        try require(cloudLogin, "Cloud race fixture login failed")
        var profileDocument: [String: Any] = [:]
        MockFirebase.handler = { request in
            try require(request.url!.path.hasSuffix("/users/demo-user/profile/details"), "Profile must use authenticated UID path")
            try require(request.value(forHTTPHeaderField: "Authorization") == "Bearer cloud-token", "Profile requests must be authenticated")
            if request.httpMethod == "PATCH" { profileDocument = try json(request) }
            return (200, profileDocument)
        }
        var profile = HouseholdProfile()
        profile.name = "Amaya"; profile.onboarded = true
        profile.personalDetails = PersonalDetails(fullName: "Amaya", phone: "0771234567", avatarData: Data([1, 2, 3]))
        try await cloudAccount.uploadProfile(JSONEncoder().encode(profile))
        let restoredProfile = try await cloudAccount.fetchProfile()
        try require(restoredProfile?.name == "Amaya" && restoredProfile?.personalDetails?.phone == "0771234567" && restoredProfile?.personalDetails?.avatarData == Data([1, 2, 3]), "Profile details and avatar must round-trip")
        MockFirebase.handler = { _ in (404, ["error": ["message": "NOT_FOUND"]]) }
        let missingProfile = try await cloudAccount.fetchProfile()
        try require(missingProfile == nil, "New accounts must have no remote profile")
        MockFirebase.handler = { _ in (403, ["error": ["message": "PERMISSION_DENIED"]]) }
        do {
            _ = try await cloudAccount.fetchProfile()
            throw NSError(domain: "ProfileTestFailure", code: 1)
        } catch let error as NSError {
            try require(error.domain == "HomeMateFirebase" && error.code == 403, "Permission failures must not be treated as missing profiles")
        }
        print("PASS: authenticated profile round-trip, avatar, missing profile and permission failure")
        var documents: [String: [String: Any]] = [:]
        var manifestRevision = 0
        var writes = 0
        MockFirebase.handler = { request in
            let path = request.url!.path
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
            if request.httpMethod == "GET" {
                return documents[path].map { (200, $0) } ?? (404, ["error": ["message": "NOT_FOUND"]])
            }
            if query.contains(where: { $0.name == "currentDocument.exists" && $0.value == "false" }), documents[path] != nil {
                return (409, ["error": ["message": "ALREADY_EXISTS"]])
            }
            if let expected = query.first(where: { $0.name == "currentDocument.updateTime" })?.value,
               documents[path]?["updateTime"] as? String != expected { return (409, ["error": ["message": "ABORTED"]]) }
            var document = try json(request)
            if path.hasSuffix("/sync/state") {
                manifestRevision += 1
                document["updateTime"] = "revision-\(manifestRevision)"
            }
            documents[path] = document; writes += 1
            return (200, document)
        }
        var snapshot = AccountSnapshot(profile: profile)
        let activity = HouseholdRecord(kind: .bill, title: "Electricity", amount: 1500)
        snapshot.records = [activity]
        snapshot.preferences.monthlyBudget = 12000
        snapshot.messages = [ChatMessage(author: "Amaya", text: "Photo and voice", photoData: Data(repeating: 42, count: 700000), audioFile: "voice.m4a", audioData: Data([4, 5, 6]))]
        try await cloudAccount.uploadAccountSnapshot(snapshot, updateTime: nil)
        let downloaded = try await cloudAccount.fetchAccountSnapshot()
        try require(try downloaded.snapshot.encoded() == snapshot.encoded(), "Multi-chunk account data and attachments must round-trip")
        try require(documents.keys.filter { $0.contains("/syncChunks/") }.count > 1, "Large attachments must span chunks")
        let beforeReuse = writes
        try await cloudAccount.uploadAccountSnapshot(snapshot, updateTime: downloaded.updateTime)
        try require(writes == beforeReuse + 1, "Unchanged chunks must be reused")
        do {
            try await cloudAccount.uploadAccountSnapshot(snapshot, updateTime: downloaded.updateTime)
            throw NSError(domain: "SyncTestFailure", code: 1)
        } catch let error as NSError {
            try require(error.domain == "HomeMateFirebase" && error.code == 409, "Concurrent manifest changes must reject stale writes")
        }
        var localEdits = snapshot, remoteEdits = snapshot
        localEdits.records.removeAll()
        let remoteTask = HouseholdRecord(kind: .task, title: "Added on second device")
        remoteEdits.records.append(remoteTask)
        remoteEdits.preferences.monthlyBudget = 17000
        localEdits.profile.household = "Updated home"
        let merged = try AccountSnapshot.merge(local: localEdits, base: snapshot, remote: remoteEdits)
        try require(merged.records.map(\.id) == [remoteTask.id], "Merge must preserve remote additions and local deletions")
        try require(merged.preferences.monthlyBudget == 17000 && merged.profile.household == "Updated home", "Unrelated device changes must both survive")
        let emptyRestore = try AccountSnapshot.merge(local: AccountSnapshot(), base: AccountSnapshot(), remote: snapshot)
        try require(try emptyRestore.encoded() == snapshot.encoded(), "Fresh devices must never replace remote data with defaults")
        print("PASS: full account chunk round-trip, photos/voice, chunk reuse, concurrent-write rejection, deletion merge and fresh device restore")
        let cloudStore = HouseholdStore()
        cloudStore.records = [HouseholdRecord(kind: .task, title: "Keep this")]
        let backupData = try JSONEncoder().encode([HouseholdRecord(kind: .task, title: "Do not restore after logout")])
        MockFirebase.handler = { _ in
            Thread.sleep(forTimeInterval: 0.1)
            return (200, ["fields":["records":["stringValue":String(decoding:backupData,as:UTF8.self)]]])
        }
        let restoring = Task { await cloudAccount.sync(store: cloudStore, restore: true) }
        while !cloudAccount.busy { await Task.yield() }
        cloudAccount.signOut(); cloudStore.scope = "user:another-user"
        await restoring.value
        try require(cloudStore.records.first?.title == "Keep this" && cloudStore.saves == 0, "A stale cloud restore crossed account boundaries")
        try require(cloudAccount.email.isEmpty && cloudAccount.userID.isEmpty, "Sign out must clear identity")
        let failingStorage = MemoryAuthStorage()
        failingStorage.value = SavedAuthSession(email: "previous@example.test", refreshToken: "old-account-token")
        failingStorage.failWrites = true
        let failing = CloudAccount(apiKey: "demo-key", projectID: "failure-project", session: session, storage: failingStorage, sessionPreferences: preferences)
        failing.signOut()
        var restoreRequests = 0
        MockFirebase.handler = { _ in restoreRequests += 1; return (500, [:]) }
        let afterLogout = CloudAccount(apiKey: "demo-key", projectID: "failure-project", session: session, storage: failingStorage, sessionPreferences: preferences)
        await afterLogout.restoreSession()
        try require(!afterLogout.signedIn && restoreRequests == 0, "Failed Keychain clearing must not restore the prior account")
        print("PASS: failed secure-storage cleanup cannot restore an old account after logout")
        print("PASS: stale cloud restores cannot change another account; invalid forms never send network requests")
        print("PASS: sign-out also invalidates in-flight authentication responses")
        print("PASS: sign-in, registration, reset request, Remember Me on/off, sign-out, session refresh/rotation, authenticated backup, and error handling")
        print("All network calls were mocked. No Firebase account, password-reset email, or Keychain item was created.")
    }
}
