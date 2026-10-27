import Foundation

@MainActor final class MemoryFamilySession: AuthSessionStorage {
    func load() throws -> SavedAuthSession? { nil }
    func save(_ value: SavedAuthSession) throws {}
    func clear() throws {}
}
final class FamilyMock: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Any))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, object) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: object)); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
@main struct VerifyFamily {
    static func require(_ value: Bool, _ message: String) throws { if !value { throw FamilyError.invalid(message) } }
    static func json(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 2048)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
        }
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
    @MainActor static func main() async throws {
        let suite = "FamilyTests-" + UUID().uuidString; let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [FamilyMock.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let account = CloudAccount(apiKey: "test", projectID: "demo-homemate", session: session, storage: MemoryFamilySession(), sessionPreferences: defaults)
        account.email = "owner@example.test"; account.password = "password123"
        FamilyMock.handler = { request in
            if request.url!.path.hasSuffix("signInWithPassword") { return (200,["idToken":"id", "refreshToken":"refresh", "localId":"owner", "expiresIn":"3600", "email":"owner@example.test"]) }
            if request.url!.path.hasSuffix("token") { return (200,["id_token":"verified", "refresh_token":"refresh", "user_id":"owner", "expires_in":"3600"]) }
            return (200,["users":[["emailVerified":true]]])
        }
        let signed = await account.authenticate(register: false); try require(signed, "Fixture login failed")
        try await account.refreshIdentity(); try require(account.emailVerified, "Email verification state not updated")
        let api = FamilyAPI(account: account)
        FamilyMock.handler = { request in
            try require(request.url!.path.hasSuffix("documents:commit"), "Family creation must use an atomic commit")
            let body = try json(request); let writes = body["writes"] as! [[String: Any]]
            try require(writes.count == 3, "Family, owner membership and personal index must be created together")
            for write in writes { try require((write["currentDocument"] as? [String:Bool])?["exists"] == false, "Creation must not overwrite existing documents") }
            return (200,[:])
        }
        let family = try await api.create(name: "Our home", displayName: "Owner", currency: "LKR")
        let invitation: [String: Any] = ["name":"projects/demo-homemate/databases/(default)/documents/familyInvites/invite", "fields":["familyID":["stringValue":family.id],"familyName":["stringValue":family.name],"email":["stringValue":"owner@example.test"],"expiresAt":["timestampValue":FirestoreRecordCodec.timestamp(Date().addingTimeInterval(86400))]]]
        FamilyMock.handler = { request in
            try require(request.url!.path.hasSuffix("documents:runQuery"), "Invitations must query the signed-in email")
            let body = try json(request); try require(String(describing:body).contains("owner@example.test"), "Email filter missing")
            return (200,[["document":invitation]])
        }
        let invites = try await api.incomingInvites(); try require(invites.count == 1, "Invitation stream parsing failed")
        FamilyMock.handler = { request in
            let writes = try json(request)["writes"] as! [[String:Any]]
            try require(writes.count == 3 && writes[0]["updateMask"] != nil, "Accept must atomically consume invitation and create membership/index")
            return (200,[:])
        }
        try await api.accept(invites[0], displayName: "Member")
        let record = HouseholdRecord(kind: .task, title: "Shared task")
        var document = try FirestoreRecordCodec.encode(record)
        document["name"] = "projects/demo-homemate/databases/(default)/documents/families/\(family.id)/records/\(record.id.uuidString)"
        document["updateTime"] = "2026-10-21T00:00:00.000Z"
        FamilyMock.handler = { _ in (200,["documents":[document]]) }
        let records = try await api.records(familyID: family.id)
        try require(records.first?.cloudRevision == "2026-10-21T00:00:00.000Z", "Shared records must retain their server revision")
        FamilyMock.handler = { request in
            try require(request.url!.path.contains("/families/\(family.id)/records/"), "Shared record escaped family namespace")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL:false)!.queryItems!
            try require(query.contains(where:{$0.name == "currentDocument.updateTime"}), "Edits must reject stale versions")
            return (200,document)
        }
        try await api.save(records[0], familyID: family.id)
        var paidBill = HouseholdRecord(kind: .bill, title: "Shared electricity bill", amount: 2400, completed: true)
        FamilyMock.handler = { request in
            let fields = try json(request)["fields"] as! [String: [String: Any]]
            try require(fields["completed"]?["booleanValue"] as? Bool == true, "Paid shared bill status must be saved")
            try require(fields["paidAt"]?["timestampValue"] as? String != nil, "Paying a shared bill must save its payment date")
            return (200,[:])
        }
        try await api.save(paidBill, familyID: family.id)
        paidBill.completed = false
        paidBill.paidAt = Date()
        FamilyMock.handler = { request in
            let fields = try json(request)["fields"] as! [String: [String: Any]]
            try require(fields["completed"]?["booleanValue"] as? Bool == false, "Reopened shared bill status must be saved")
            try require(fields["paidAt"] == nil, "Reopening a shared bill must clear its payment date")
            return (200,[:])
        }
        try await api.save(paidBill, familyID: family.id)
        print("PASS: verified identity, family access, record conflicts, and shared bill payment dates")
    }
}
