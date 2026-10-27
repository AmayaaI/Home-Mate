import Foundation
import Combine

@MainActor
final class SharedFamilyViewModel: ScreenViewModel {
    @Published var records: [HouseholdRecord] = []
    @Published var members: [FamilyMember] = []
    @Published var kind: RecordKind = .task
    @Published var selected: HouseholdRecord?
    @Published var pendingDelete: HouseholdRecord?
    @Published var error: String?
    @Published var loading = false
    @Published var writing = false

    var api: FamilyAPI { FamilyAPI(account: account) }
    var filtered: [HouseholdRecord] {
        let matching = records.filter {
            kind == .expense ? ExpenseIntelligence.spendingDate(for: $0) != nil : $0.kind == kind
        }
        if kind == .expense {
            return matching.sorted {
                (ExpenseIntelligence.spendingDate(for: $0) ?? $0.date) >
                    (ExpenseIntelligence.spendingDate(for: $1) ?? $1.date)
            }
        }
        return matching
    }
    func refresh() async {
        guard isActive, !loading else { return }; loading = true; let scope = account.dataScope
        defer { loading = false }
        do {
            guard let refreshedFamily = try await api.families().first(where: { $0.id == family.id }) else {
                throw FamilyError.invalid("This family is no longer available.")
            }
            let members = try await api.members(familyID: family.id)
            let records = try await api.records(familyID: family.id)
            guard account.dataScope == scope, !Task.isCancelled else { return }
            self.family = refreshedFamily
            self.members = members; self.records = records; error = nil
        } catch {
            if account.dataScope == scope, !Task.isCancelled {
                records = []; members = []
                if (error as NSError).code == 403 { selected = nil }
                self.error = "Could not open this family. Check your connection and membership. " + error.localizedDescription
            }
        }
    }
    func mutate(_ operation: @escaping @MainActor () async throws -> Void) {
        guard isActive, !writing else { return }; writing = true
        Task {
            defer { writing = false }
            do { try await operation(); await refresh() }
            catch { self.error = error.localizedDescription + " Refresh before retrying if another member edited this activity." }
        }
    }

    @Published private(set) var family: SharedFamily
    init(store: HouseholdStore, account: CloudAccount, family: SharedFamily) {
        self.family = family
        super.init(store: store, account: account)
    }

    func addActivity() { selected = HouseholdRecord(kind: kind, title: "", assignee: account.email) }
    func toggleShared(_ record: HouseholdRecord) {
        var updated = record; updated.completed.toggle()
        mutate { try await self.api.save(updated, familyID: self.family.id) }
    }
    func deletePending() {
        guard let record = pendingDelete else { return }; pendingDelete = nil
        mutate { try await self.api.delete(record, familyID: self.family.id) }
    }
    func save(_ record: HouseholdRecord) async throws { guard isActive else { throw CancellationError() }; try await api.save(record, familyID: family.id) }
    func monitor(active: Bool) async {
        guard active, isActive else { return }
        while !Task.isCancelled {
            if !writing { await refresh() }
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
        }
    }

}
