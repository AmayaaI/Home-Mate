import Foundation
import Combine

/// Shared data is held separately from Core Data's private account snapshots.
/// One foreground refresh loop feeds all main tabs; account/context generations reject stale responses.
@MainActor
final class HouseholdContext: ObservableObject {
    @Published private(set) var arrivalRecords: [String: [HouseholdRecord]] = [:]
    @Published private(set) var families: [SharedFamily] = []
    @Published private(set) var family: SharedFamily?
    @Published private(set) var records: [HouseholdRecord] = []
    @Published private(set) var members: [FamilyMember] = []
    @Published private(set) var announcements: [FamilyAnnouncement] = []
    @Published private(set) var loading = false
    @Published private(set) var writing = false
    @Published var error: String?
    @Published private(set) var lastUpdated: Date?
    private let account: CloudAccount
    private var accountScope: String
    private var generation = UUID()
    private var loadingGeneration: UUID?
    private var accountObservation: AnyCancellable?

    init(account: CloudAccount) {
        self.account = account
        accountScope = account.dataScope
        accountObservation = account.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.resetIfAccountChanged() }
        }
    }
    var authorisedArrivalRecords: [String: [HouseholdRecord]] { accountScope == account.dataScope ? arrivalRecords : [:] }
    var identity: String { account.dataScope + ":" + (family?.id ?? "private") }
    var canWrite: Bool { family != nil && lastUpdated != nil && !loading && !writing && error == nil && accountScope == account.dataScope }
    private func resetIfAccountChanged() {
        guard accountScope != account.dataScope else { return }
        generation = UUID(); accountScope = account.dataScope; families = []; family = nil
        records = []; arrivalRecords = [:]; members = []; announcements = []; lastUpdated = nil
        loadingGeneration = nil; loading = false; writing = false; error = nil
    }
    func select(_ value: SharedFamily?) {
        guard value?.id != family?.id || accountScope != account.dataScope else { return }
        generation = UUID(); family = value; records = []; members = []; announcements = []
        lastUpdated = nil; loadingGeneration = nil; loading = false; writing = false; error = nil
    }
    func refresh() async {
        resetIfAccountChanged()
        guard account.signedIn else { return }
        let request = generation, scope = account.dataScope, selected = family
        guard loadingGeneration != request else { return }
        loadingGeneration = request; loading = true
        defer { if generation == request { loading = false; loadingGeneration = nil } }
        func current() -> Bool { generation == request && account.dataScope == scope && !Task.isCancelled }
        do {
            let api = FamilyAPI(account: account)
            let available = try await api.families()
            guard current() else { return }
            families = available
            var arrival: [String: [HouseholdRecord]] = [:]
            for candidate in available {
                let values = try? await api.records(familyID: candidate.id)
                guard current() else { return }
                if let values { arrival[candidate.id] = values }
            }
            arrivalRecords = arrival
            if let selected {
                guard let refreshedFamily = available.first(where: { $0.id == selected.id }) else {
                    select(nil); error = "This family is no longer available. Showing your private household."; return
                }
                // Refresh metadata without changing the household identity or clearing its records.
                family = refreshedFamily
                async let nextMembers = api.members(familyID: selected.id)
                guard let nextRecords = arrival[selected.id] else { throw FamilyError.invalid("Could not verify access to this household’s activities.") }
                async let nextAnnouncements = api.announcements(familyID: selected.id)
                let values = try await (nextMembers, nextAnnouncements)
                guard current() else { return }
                members = values.0; records = nextRecords; announcements = values.1
            }
            error = nil; lastUpdated = Date()
        } catch {
            guard current() else { return }
            // Do not retain shared information after permission revocation or an unverified refresh.
            arrivalRecords = [:]
            records = []; members = []; announcements = []
            self.error = "Could not refresh household data. Check your connection and membership. " + error.localizedDescription
        }
    }
    func monitor(active: Bool) async {
        guard active else { return }
        while !Task.isCancelled {
            if !writing { await refresh() }
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
        }
    }
    func save(_ record: HouseholdRecord, expectedIdentity: String) async throws {
        guard identity == expectedIdentity, accountScope == account.dataScope, let family else {
            throw FamilyError.invalid("The selected household changed. Open this activity in the correct household.")
        }
        guard account.signedIn else { throw FamilyError.invalid("Sign in again to save to your shared household.") }
        guard !writing else { throw FamilyError.invalid("Another household change is saving. Please try again shortly.") }
        let request = generation
        writing = true
        defer { if request == generation { writing = false } }
        try await FamilyAPI(account: account).save(record, familyID: family.id)
        guard request == generation else { throw CancellationError() }
        await refresh()
        // The write succeeded. A separate feed refresh must not report it as a
        // failed save and encourage a duplicate create on retry.
    }
    func toggle(_ record: HouseholdRecord) async {
        guard let latest = records.first(where: { $0.id == record.id }), latest.completed == record.completed else { return }
        var changed = latest; changed.completed.toggle()
        let expected = identity
        do { try await save(changed, expectedIdentity: identity) }
        catch { if expected == identity { self.error = error.localizedDescription } }
    }
    func delete(_ record: HouseholdRecord) async {
        guard canWrite, let family else { return }
        let request = generation
        writing = true
        defer { if request == generation { writing = false } }
        do {
            try await FamilyAPI(account: account).delete(record, familyID: family.id)
            if request == generation { await refresh() }
        } catch { if request == generation { self.error = error.localizedDescription } }
    }
    func saveAnnouncement(_ value: FamilyAnnouncement, expectedIdentity: String) async throws {
        guard identity == expectedIdentity, canWrite, let family else { throw FamilyError.invalid("Refresh this household before saving.") }
        let request = generation
        writing = true
        defer { if request == generation { writing = false } }
        try await FamilyAPI(account: account).saveAnnouncement(value, familyID: family.id)
        guard request == generation else { throw CancellationError() }
        await refresh()
        if let error { throw FamilyError.invalid(error) }
    }
    func deleteAnnouncement(_ value: FamilyAnnouncement) async {
        guard canWrite, let family else { return }
        let request = generation
        writing = true
        defer { if request == generation { writing = false } }
        do {
            try await FamilyAPI(account: account).deleteAnnouncement(value, familyID: family.id)
            if request == generation { await refresh() }
        } catch { if request == generation { self.error = error.localizedDescription } }
    }
}
