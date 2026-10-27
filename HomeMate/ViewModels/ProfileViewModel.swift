import Foundation
import Combine
import PhotosUI
import SwiftUI

@MainActor
final class ProfileViewModel: ScreenViewModel {
    @Published var draft = PersonalDetails()
    @Published var photo: PhotosPickerItem?
    @Published var loadingPhoto = false
    @Published var message: String?
    @Published var loaded = false

    func save() -> Bool {
        guard isActive else { return false }
        let email = draft.email.trimmingCharacters(in: .whitespacesAndNewlines)
        if !email.isEmpty && !InputValidation.email(email) { message = "Enter a valid contact email address."; return false }
        draft.fullName = draft.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.nickname = draft.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.email = email
        guard !draft.nickname.isEmpty || !draft.fullName.isEmpty else { message = "Enter your full name or nickname."; return false }
        guard InputValidation.mobile(draft.phone, countryCode: draft.countryCode) else { message = "Enter a valid mobile number. For +94 use 0771234567 or 771234567."; return false }
        guard InputValidation.phone(draft.emergencyPhone) else { message = "Enter a valid emergency phone number."; return false }
        let previousProfile = store.profile
        let previousRecords = store.records
        let previousName = store.profile.name
        store.profile.personalDetails = draft
        store.profile.name = draft.nickname.isEmpty ? draft.fullName : draft.nickname
        if previousName != store.profile.name {
            store.profile.members = store.profile.memberNames.map { $0 == previousName ? store.profile.name : $0 }.joined(separator: ", ")
            for index in store.records.indices where store.records[index].assignee == previousName { store.records[index].assignee = store.profile.name }
        }
        if store.save() { return true }
        else { message = store.error; store.profile = previousProfile; store.records = previousRecords; return false }
    }

    let accountEmailInput: String
    init(store: HouseholdStore, account: CloudAccount, accountEmail: String) {
        accountEmailInput = accountEmail
        super.init(store: store, account: account)
    }
    func loadIfNeeded() {
        guard !loaded else { return }; loaded = true
        draft = store.profile.personalDetails ?? PersonalDetails()
        if draft.fullName.isEmpty { draft.fullName = store.profile.name }
        if draft.nickname.isEmpty { draft.nickname = store.profile.name }
        if draft.email.isEmpty { draft.email = accountEmailInput }
    }
    var validMobile: Bool { InputValidation.mobile(draft.phone, countryCode: draft.countryCode) }
    var validEmergencyPhone: Bool { InputValidation.phone(draft.emergencyPhone) }
    var canSave: Bool { !loadingPhoto && (!draft.fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) && validMobile && validEmergencyPhone }
    func loadPhoto(_ selection: PhotosPickerItem?) async {
        loadingPhoto = true; defer { loadingPhoto = false }
        let scope = account.dataScope
        do {
            guard let data = try await selection?.loadTransferable(type: Data.self) else { message = "Could not open that photo."; return }
            let thumbnail = try ImageAttachmentService.profileThumbnail(data)
            guard isCurrent(scope) else { return }
            draft.avatarData = thumbnail; message = nil
        } catch { if isCurrent(scope) { message = error.localizedDescription } }
    }

}
