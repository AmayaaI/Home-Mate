import Foundation
import Combine

@MainActor
final class ShareRecordViewModel: ScreenViewModel {
    @Published var families: [SharedFamily] = []
    @Published var error: String?
    @Published var busy = false
    @Published var shared = false
    @Published var chosen: SharedFamily?
    @Published var members: [FamilyMember] = []
    @Published var assignee = "Everyone"

    let record: HouseholdRecord
    init(store: HouseholdStore, account: CloudAccount, record: HouseholdRecord) {
        self.record = record
        super.init(store: store, account: account)
    }
    func load() async {
        guard isActive else { return }
        let scope = account.dataScope
        do { let result = try await FamilyAPI(account: account).families(); if isCurrent(scope) { families = result; error = nil } }
        catch { if isCurrent(scope) { families = []; self.error = error.localizedDescription } }
    }
    func choose(_ family: SharedFamily) async {
        guard isActive, !busy else { return }
        let scope = account.dataScope
        busy = true; defer { busy = false }
        do {
            let members = try await FamilyAPI(account: account).members(familyID: family.id)
            guard isCurrent(scope) else { return }
            self.members = members
            chosen = family
            assignee = defaultAssignee(from: record, members: members)
            error = nil
        } catch { if isCurrent(scope) { self.error = error.localizedDescription } }
    }
    func share() async {
        guard let family = chosen else { return }
        guard isActive, !busy, !shared else { return }
        let scope = account.dataScope
        chosen = nil; busy = true; defer { busy = false }
        do {
            var copy = record
            copy.id = UUID(); copy.cloudRevision = nil
            if copy.kind != .expense { copy.assignee = assignee }
            try await FamilyAPI(account: account).save(copy, familyID: family.id)
            if isCurrent(scope) { shared = true }
        } catch { if isCurrent(scope) { self.error = error.localizedDescription } }
    }

    private func defaultAssignee(from record: HouseholdRecord, members: [FamilyMember]) -> String {
        guard record.kind != .event, record.kind != .expense else { return "Everyone" }
        let value = record.assignee.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.caseInsensitiveCompare("Me") == .orderedSame || (!profile.name.isEmpty && value.caseInsensitiveCompare(profile.name) == .orderedSame) {
            return account.email
        }
        return members.contains(where: { $0.email.caseInsensitiveCompare(value) == .orderedSame }) ? value : "Everyone"
    }

}
