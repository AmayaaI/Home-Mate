import Foundation
import Combine
import Security
import CryptoKit

struct SavedAuthSession: Codable {
    var email: String
    var refreshToken: String
}
@MainActor
protocol AuthSessionStorage {
    func load() throws -> SavedAuthSession?
    func save(_ session: SavedAuthSession) throws
    func clear() throws
}
@MainActor
final class KeychainAuthStorage: AuthSessionStorage {
    private let service: String
    init(service: String) { self.service = service }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "firebase-session"]
    }
    func load() throws -> SavedAuthSession? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw keychainError(status) }
        return try JSONDecoder().decode(SavedAuthSession.self, from: data)
    }
    func save(_ session: SavedAuthSession) throws {
        let data = try JSONEncoder().encode(session)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let result = SecItemAdd(item as CFDictionary, nil)
            guard result == errSecSuccess else { throw keychainError(result) }
        } else if status != errSecSuccess { throw keychainError(status) }
    }
    func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw keychainError(status) }
    }
    private func keychainError(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Secure session storage is unavailable (\(status))."])
    }
}

@MainActor
final class CloudAccount: ObservableObject {
    @Published var email = ""
    @Published var password = ""
    @Published var message = ""
    @Published var isError = false
    @Published var busy = false
    @Published var signedIn = false
    @Published private(set) var emailVerified = false
    @Published var rememberSession = true
    private var token = ""
    private var refreshToken = ""
    private var knownSyncChunkIDs: [String: Set<String>] = [:]
    private(set) var userID = ""
    var dataScope: String { signedIn ? "user:" + userID : "guest" }
    private var expiresAt = Date.distantPast
    private var sessionGeneration = UUID()
    private let session: URLSession
    private let storage: any AuthSessionStorage
    private let sessionPreferences: UserDefaults
    private var restorePreferenceKey: String { "authSessionRestoreAllowed." + projectID }
    let apiKey: String
    let projectID: String
    var configured: Bool { !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !projectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    init(apiKey: String? = nil, projectID: String? = nil, session: URLSession = .shared, storage: (any AuthSessionStorage)? = nil, sessionPreferences: UserDefaults = .standard) {
        self.apiKey = apiKey ?? Bundle.main.object(forInfoDictionaryKey: "FirebaseAPIKey") as? String ?? ""
        self.projectID = projectID ?? Bundle.main.object(forInfoDictionaryKey: "FirebaseProjectID") as? String ?? ""
        self.session = session
        self.sessionPreferences = sessionPreferences
        self.storage = storage ?? KeychainAuthStorage(service: "com.homemate.firebase.\(self.projectID)")
    }
    private func authURL(_ action: String) -> URL {
        var components = URLComponents(string: "https://identitytoolkit.googleapis.com/v1/accounts:\(action)")!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        return components.url!
    }
    private func request(_ url: URL, method: String = "POST", body: [String: Any], authenticated: Bool = false) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authenticated { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await response(for: request)
    }
    private func response(for request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        let decoded = try? JSONSerialization.jsonObject(with: data)
        let object = decoded as? [String: Any] ?? ["documents": (decoded as? [[String: Any]] ?? []).compactMap { $0["document"] }]
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let detail = (object["error"] as? [String: Any])?["message"] as? String ?? "Unable to connect. Please try again."
            throw NSError(domain: "HomeMateFirebase", code: (response as? HTTPURLResponse)?.statusCode ?? 0, userInfo: [NSLocalizedDescriptionKey: friendly(detail)])
        }
        return object
    }
    private func friendly(_ code: String) -> String {
        switch code.components(separatedBy: " : ").first ?? code {
        case "CONFIGURATION_NOT_FOUND": "Firebase Authentication is not set up. Open Firebase Console → Authentication → Get started, then enable Email/Password."
        case "API_KEY_INVALID": "The Firebase client configuration is invalid."
        case "INVALID_EMAIL": "Enter a valid email address."
        case "EMAIL_EXISTS": "This email already has an account. Try signing in."
        case "INVALID_LOGIN_CREDENTIALS", "EMAIL_NOT_FOUND", "INVALID_PASSWORD": "The email or password is incorrect."
        case "WEAK_PASSWORD": "Use a password that meets your Firebase project's password policy."
        case "USER_DISABLED": "This account has been disabled."
        case "TOO_MANY_ATTEMPTS_TRY_LATER": "Too many attempts. Please try again later."
        case "OPERATION_NOT_ALLOWED": "Email/password sign-in is not enabled for this project."
        case "INVALID_REFRESH_TOKEN", "TOKEN_EXPIRED", "USER_NOT_FOUND": "Your session has expired. Sign in again."
        default: code
        }
    }
    @discardableResult
    func authenticate(register: Bool) async -> Bool {
        guard !busy else { return false }
        guard configured else { message = "Online accounts are unavailable because this app’s Firebase configuration is missing. Connect the Firebase project and enable Email/Password sign-in, then rebuild the app. You can use Continue on this device in the meantime."; isError = true; return false }
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard InputValidation.email(address), !password.isEmpty else { message = "Enter your email and password."; isError = true; return false }
        guard !register || (password.count >= 6 && password.utf8.count <= 4096) else {
            message = "Use a password with at least 6 characters (maximum 4096 bytes)."; isError = true; return false
        }
        busy = true; message = ""; isError = false
        let generation = sessionGeneration
        defer { busy = false }
        do {
            let result = try await request(authURL(register ? "signUp" : "signInWithPassword"), body: ["email": address, "password": password, "returnSecureToken": true])
            guard generation == sessionGeneration else { return false }
            guard let idToken = result["idToken"] as? String, !idToken.isEmpty,
                  let uid = result["localId"] as? String, !uid.isEmpty,
                  let refresh = result["refreshToken"] as? String, !refresh.isEmpty else { throw URLError(.cannotParseResponse) }
            emailVerified = false
            token = idToken; userID = uid; refreshToken = refresh; email = result["email"] as? String ?? address
            expiresAt = Date().addingTimeInterval(Double(result["expiresIn"] as? String ?? "3600") ?? 3600)
            password = ""
            do { try persistSession() }
            catch { message = "Signed in for this launch, but the saved-session preference could not be updated."; isError = false }
            signedIn = true
            if message.isEmpty { message = "Signed in. Your household is ready." }
            return true
        } catch {
            guard generation == sessionGeneration else { return false }
            message = error.localizedDescription; isError = true; return false
        }
    }
    private func persistSession() throws {
        // If Keychain saving/clearing fails, never restore an older account on next launch.
        sessionPreferences.set(false, forKey: restorePreferenceKey)
        if rememberSession {
            try storage.save(SavedAuthSession(email: email, refreshToken: refreshToken))
            sessionPreferences.set(true, forKey: restorePreferenceKey)
        } else { try storage.clear() }
    }
    // Restore from a refresh token, never from a stored password or stale ID token.
    func restoreSession() async {
        guard configured, !signedIn, !busy, sessionPreferences.object(forKey: restorePreferenceKey) as? Bool != false else { return }
        let generation = sessionGeneration
        do {
            guard let saved = try storage.load() else { return }
            email = saved.email; refreshToken = saved.refreshToken; rememberSession = true
            busy = true; defer { busy = false }
            try await refreshIDToken()
            signedIn = true; message = ""; isError = false
        } catch is CancellationError {
            return
        } catch {
            guard generation == sessionGeneration else { return }
            token = ""; refreshToken = ""; userID = ""; signedIn = false
            // Keep a remembered refresh token after transient connectivity failures.
            message = "Could not restore your session. Sign in or continue on this device."; isError = true
        }
    }
    private func refreshIDToken() async throws {
        guard !refreshToken.isEmpty else { throw URLError(.userAuthenticationRequired) }
        let generation = sessionGeneration
        var components = URLComponents(string: "https://securetoken.googleapis.com/v1/token")!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"; request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token"), URLQueryItem(name: "refresh_token", value: refreshToken)]
        request.httpBody = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let result = try await response(for: request)
        guard generation == sessionGeneration else { throw CancellationError() }
        guard let newToken = result["id_token"] as? String, !newToken.isEmpty,
              let uid = result["user_id"] as? String, !uid.isEmpty,
              userID.isEmpty || userID == uid,
              let refresh = result["refresh_token"] as? String, !refresh.isEmpty else { throw URLError(.cannotParseResponse) }
        token = newToken; userID = uid; refreshToken = refresh
        expiresAt = Date().addingTimeInterval(Double(result["expires_in"] as? String ?? "3600") ?? 3600)
        do { try persistSession() }
        catch { message = "Session refreshed for this launch. Secure session storage is unavailable." }
    }
    func sendPasswordReset(to address: String) async {
        guard !busy else { return }
        guard configured else { message = "Cloud sign-in is not connected yet."; isError = true; return }
        let email = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard InputValidation.email(email) else { message = "Enter a valid email address."; isError = true; return }
        busy = true; message = ""; isError = false; defer { busy = false }
        do {
            _ = try await request(authURL("sendOobCode"), body: ["requestType": "PASSWORD_RESET", "email": address.trimmingCharacters(in: .whitespacesAndNewlines)])
            message = "If this email has an account, a reset link has been sent. Check your inbox."
        } catch { message = error.localizedDescription; isError = true }
    }
    func sync(store: HouseholdStore, restore: Bool) async {
        let expectedScope = dataScope
        guard signedIn, !busy, store.scope == expectedScope else { return }
        let generation = sessionGeneration
        busy = true; message = ""; isError = false; defer { busy = false }
        do {
            if restore {
                let object = try await firestoreRequest(path: [])
                guard generation == sessionGeneration, store.scope == expectedScope else { return }
                guard let fields = object["fields"] as? [String: Any], let payload = fields["records"] as? [String: Any], let encoded = payload["stringValue"] as? String, let data = encoded.data(using: .utf8) else { throw URLError(.cannotParseResponse) }
                let records = try JSONDecoder().decode([HouseholdRecord].self, from: data)
                guard store.replaceRecords(records, expectedScope: expectedScope) else {
                    message = store.error ?? "Cloud restore could not be saved."; isError = true; return
                }
                message = "Cloud records restored."
            } else {
                guard store.records.allSatisfy({ $0.validationError == nil }) else { throw FirestoreRecordCodec.InvalidDocument.invalid }
                let data = try JSONEncoder().encode(store.records)
                guard data.count <= 800000 else {
                    message = "This backup is too large. Save records individually to the cloud."; isError = true; return
                }
                _ = try await firestoreRequest(path: [], method: "PATCH", body: ["fields": ["records": ["stringValue": String(decoding: data, as: UTF8.self)]]])
                guard generation == sessionGeneration, store.scope == expectedScope else { return }
                message = "Household records backed up."
            }
        } catch is CancellationError { return }
        catch {
            guard generation == sessionGeneration, store.scope == expectedScope else { return }
            message = error.localizedDescription; isError = true
        }
    }
    func refreshIdentity() async throws {
        guard signedIn else { throw URLError(.userAuthenticationRequired) }
        let generation = sessionGeneration
        try await refreshIDToken()
        let result = try await request(authURL("lookup"), body: ["idToken": token])
        guard generation == sessionGeneration else { throw CancellationError() }
        guard let users = result["users"] as? [[String: Any]], let identity = users.first else { throw URLError(.cannotParseResponse) }
        emailVerified = identity["emailVerified"] as? Bool ?? false
    }
    func sendVerificationEmail() async throws {
        guard signedIn else { throw URLError(.userAuthenticationRequired) }
        if expiresAt.timeIntervalSinceNow < 60 { try await refreshIDToken() }
        _ = try await request(authURL("sendOobCode"), body: ["requestType": "VERIFY_EMAIL", "idToken": token])
    }
    // Private records remain under their owner's UID. Shared families have separate paths.
    func firestoreRequest(path: [String], method: String = "GET", body: [String: Any]? = nil, query: [URLQueryItem] = []) async throws -> [String: Any] {
        try await documentRequest(path: ["households", userID] + path, method: method, body: body, query: query)
    }
    func documentRequest(path: [String], method: String = "GET", body: [String: Any]? = nil, query: [URLQueryItem] = [], operation: String? = nil) async throws -> [String: Any] {
        guard signedIn else { throw URLError(.userAuthenticationRequired) }
        let generation = sessionGeneration
        if expiresAt.timeIntervalSinceNow < 60 { try await refreshIDToken() }
        guard generation == sessionGeneration, signedIn else { throw CancellationError() }
        let root = "https://firestore.googleapis.com/v1/projects/\(projectID)/databases/(default)/documents"
        var url = URL(string: root)!
        for part in path { url.appendPathComponent(part) }
        if let operation {
            guard ["commit", "runQuery"].contains(operation) else { throw URLError(.unsupportedURL) }
            url = URL(string: url.absoluteString + ":" + operation)!
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method; request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let result = try await response(for: request)
        guard generation == sessionGeneration, signedIn else { throw CancellationError() }
        return result
    }
    struct AccountCloudState {
        var snapshot: AccountSnapshot
        var updateTime: String?
    }
    private func chunkID(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    func fetchAccountSnapshot() async throws -> AccountCloudState {
        guard let snapshot = try await fetchAccountSnapshot(ifUnchangedSince: nil) else {
            throw URLError(.cannotParseResponse)
        }
        return snapshot
    }
    /// Always reads the small manifest, but skips all chunk reads when the cloud
    /// snapshot has not changed since the caller's last successful sync.
    func fetchAccountSnapshot(ifUnchangedSince previousUpdateTime: String?) async throws -> AccountCloudState? {
        let uid = userID
        let generation = sessionGeneration
        let manifest: [String: Any]
        do { manifest = try await documentRequest(path: ["users", uid, "sync", "state"]) }
        catch let error as NSError where error.domain == "HomeMateFirebase" && error.code == 404 {
            // Upgrade accounts which used the earlier profile-only sync.
            let profile = try await fetchProfile() ?? HouseholdProfile()
            guard generation == sessionGeneration else { throw CancellationError() }
            return AccountCloudState(snapshot: AccountSnapshot(profile: profile), updateTime: nil)
        }
        guard let fields = manifest["fields"] as? [String: [String: Any]],
              fields["version"]?["integerValue"] as? String == "1",
              let array = fields["chunks"]?["arrayValue"] as? [String: Any],
              let values = array["values"] as? [[String: String]], !values.isEmpty, values.count <= 128,
              let updateTime = manifest["updateTime"] as? String else { throw URLError(.cannotParseResponse) }
        if updateTime == previousUpdateTime { return nil }
        var data = Data()
        var fetchedChunkIDs = Set<String>()
        for value in values {
            guard generation == sessionGeneration else { throw CancellationError() }
            guard let id = value["stringValue"], id.count == 64, id.allSatisfy({ $0.isHexDigit }) else { throw URLError(.cannotParseResponse) }
            let document = try await documentRequest(path: ["users", uid, "syncChunks", id])
            guard let fields = document["fields"] as? [String: [String: Any]],
                  let encoded = fields["data"]?["bytesValue"] as? String,
                  let chunk = Data(base64Encoded: encoded), chunk.count <= 450000,
                  chunkID(chunk) == id else { throw URLError(.cannotParseResponse) }
            data.append(chunk)
            fetchedChunkIDs.insert(id)
        }
        guard generation == sessionGeneration else { throw CancellationError() }
        knownSyncChunkIDs[uid] = fetchedChunkIDs
        return AccountCloudState(snapshot: try JSONDecoder().decode(AccountSnapshot.self, from: data), updateTime: updateTime)
    }
    /// Content-addressed chunks are immutable. The manifest is published last with a
    /// server precondition, so readers never observe partial uploads or lost concurrent writes.
    @discardableResult
    func uploadAccountSnapshot(_ snapshot: AccountSnapshot, updateTime: String?) async throws -> String? {
        let data = try snapshot.encoded()
        guard data.count <= 450000 * 128 else {
            throw NSError(domain: "HomeMateSync", code: 3, userInfo: [NSLocalizedDescriptionKey: "Your account exceeds the 57 MB sync limit. Remove large attachments and retry. Your local data is safe."])
        }
        let uid = userID, generation = sessionGeneration
        var knownIDs = knownSyncChunkIDs[uid] ?? []
        var ids: [String] = []
        for offset in stride(from: 0, to: data.count, by: 450000) {
            guard generation == sessionGeneration else { throw CancellationError() }
            let chunk = data.subdata(in: offset..<min(offset + 450000, data.count))
            let id = chunkID(chunk); ids.append(id)
            if knownIDs.contains(id) { continue }
            func existingChunkMatches() async throws -> Bool {
                do {
                    let document = try await documentRequest(path: ["users", uid, "syncChunks", id])
                    guard let fields = document["fields"] as? [String: [String: Any]],
                          let encoded = fields["data"]?["bytesValue"] as? String,
                          Data(base64Encoded: encoded) == chunk else { throw URLError(.cannotParseResponse) }
                    return true
                } catch let error as NSError where error.domain == "HomeMateFirebase" && error.code == 404 { return false }
            }
            if try await existingChunkMatches() { continue }
            guard generation == sessionGeneration else { throw CancellationError() }
            do {
                _ = try await documentRequest(path: ["users", uid, "syncChunks", id], method: "PATCH",
                    body: ["fields": ["data": ["bytesValue": chunk.base64EncodedString()]]],
                    query: [URLQueryItem(name: "currentDocument.exists", value: "false")])
            } catch let error as NSError where error.domain == "HomeMateFirebase" && [403, 409, 412].contains(error.code) {
                // Another device may have created the identical immutable chunk.
                guard generation == sessionGeneration else { throw CancellationError() }
                guard try await existingChunkMatches() else { throw error }
            }
            knownIDs.insert(id)
        }
        guard generation == sessionGeneration else { throw CancellationError() }
        let precondition = updateTime.map { URLQueryItem(name: "currentDocument.updateTime", value: $0) }
            ?? URLQueryItem(name: "currentDocument.exists", value: "false")
        let manifest = try await documentRequest(path: ["users", uid, "sync", "state"], method: "PATCH", body: ["fields": [
            "version": ["integerValue": "1"],
            "chunks": ["arrayValue": ["values": ids.map { ["stringValue": $0] }]]
        ]], query: [precondition])
        knownSyncChunkIDs[uid] = Set(ids)
        return manifest["updateTime"] as? String
    }
    func fetchProfile() async throws -> HouseholdProfile? {
        do {
            let document = try await documentRequest(path: ["users", userID, "profile", "details"])
            guard let fields = document["fields"] as? [String: Any],
                  let payload = fields["payload"] as? [String: Any],
                  let json = payload["stringValue"] as? String else { throw URLError(.cannotParseResponse) }
            let profile = try JSONDecoder().decode(HouseholdProfile.self, from: Data(json.utf8))
            if let problem = profile.validationError {
                throw NSError(domain: "HomeMateProfile", code: 1, userInfo: [NSLocalizedDescriptionKey: problem])
            }
            return profile
        } catch let error as NSError where error.domain == "HomeMateFirebase" && error.code == 404 {
            return nil
        }
    }
    func uploadProfile(_ data: Data) async throws {
        guard data.count <= 800000 else {
            throw NSError(domain: "HomeMateProfile", code: 2, userInfo: [NSLocalizedDescriptionKey: "Your profile photo is too large to sync. Choose a smaller photo."])
        }
        _ = try await documentRequest(path: ["users", userID, "profile", "details"], method: "PATCH", body: ["fields": [
            "payload": ["stringValue": String(decoding: data, as: UTF8.self)],
            "version": ["integerValue": "1"]
        ]])
    }
    func signOut() {
        sessionPreferences.set(false, forKey: restorePreferenceKey)
        sessionGeneration = UUID()
        token = ""; refreshToken = ""; userID = ""; password = ""; expiresAt = .distantPast; email = ""; emailVerified = false; signedIn = false
        do { try storage.clear(); message = "Signed out."; isError = false }
        catch { message = "Signed out for this launch, but the saved session could not be removed."; isError = true }
    }
}
