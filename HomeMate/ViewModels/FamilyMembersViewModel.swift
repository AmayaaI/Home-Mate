import Foundation
import Combine

@MainActor
final class FamilyMembersViewModel: ScreenViewModel {
    @Published var members: [FamilyMember] = []
    @Published var invitations: [FamilyInvitation] = []
    @Published var email = ""
    @Published var busy = false
    @Published var error: String?
    @Published var notice: String?
    @Published var removing: FamilyMember?
    @Published var nameDraft = ""

    var api: FamilyAPI { FamilyAPI(account: account) }
    var owner: Bool { family.ownerID == account.userID }
    var ownerMember: FamilyMember? { members.first(where: { $0.role == "owner" }) }
    var householdMembers: [FamilyMember] { members.filter { $0.role != "owner" } }
    var memberSummary: String { members.count == 1 ? "1 active member" : "\(members.count) active members" }
    var pendingSummary: String { invitations.count == 1 ? "1 invitation pending" : "\(invitations.count) invitations pending" }
    func load() async {
        guard isActive else { return }
        do {
            guard let refreshedFamily = try await api.families().first(where: { $0.id == family.id }) else {
                throw FamilyError.invalid("This family is no longer available.")
            }
            let refreshedMembers = try await api.members(familyID: family.id)
            let refreshedInvitations = refreshedFamily.ownerID == account.userID ? try await api.sentInvites(familyID: family.id) : []
            guard isActive, !Task.isCancelled else { return }
            family = refreshedFamily; members = refreshedMembers; invitations = refreshedInvitations
            error = nil
        } catch {
            guard isActive, !Task.isCancelled else { return }
            members = []; invitations = []; self.error = error.localizedDescription
        }
    }
    func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard isActive, !busy else { return }; busy = true; error = nil
        Task { defer { busy = false }; do { try await action(); await load() } catch { self.error = error.localizedDescription } }
    }

    @Published var family: SharedFamily
    init(store: HouseholdStore, account: CloudAccount, family: SharedFamily) {
        self.family = family
        super.init(store: store, account: account)
    }

    @Published var didLeave = false
    var validEmail: Bool { InputValidation.email(email) }
    func invite() {
        let recipient = email
        perform { try await self.api.invite(email: recipient, family: self.family); self.email = ""; self.notice = "Invitation created in HomeMate. No email was sent. Use Share instructions to notify them; they can accept in Family & sharing after signing in and verifying that email." }
    }
    func cancel(_ invite: FamilyInvitation) { perform { try await self.api.cancel(invite) } }
    func prepareRename() { nameDraft = family.name }
    func rename() {
        let name = nameDraft
        perform {
            try await self.api.rename(family: self.family, name: name)
            self.family.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            self.notice = "Household renamed."
        }
    }
    func removePending() {
        guard let member = removing else { return }; removing = nil
        perform { try await self.api.remove(member: member, familyID: self.family.id); if member.id == self.account.userID { self.didLeave = true } }
    }

}
