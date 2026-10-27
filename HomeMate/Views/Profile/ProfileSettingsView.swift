import SwiftUI
import PhotosUI

struct ProfileSettingsView: View {
    @EnvironmentObject private var dependencies: AppDependencies
    var accountEmail: String
    var body: some View {
        ViewModelHost(make: ProfileViewModel(store: dependencies.store, account: dependencies.account, accountEmail: accountEmail)) { model in
            ProfileSettingsViewScreen(viewModel: model)
        }.id(dependencies.account.dataScope)
    }
}

private struct ProfileSettingsViewScreen: View {

    @Environment(\.dismiss) private var dismiss




    @State private var showNIC = false
    @State private var editEmergency = false

    private let green = DashboardPalette.green
    private var accountEmail: String { viewModel.accountEmailInput }
    @ObservedObject var viewModel: ProfileViewModel
    private var draft: PersonalDetails { get { viewModel.draft } nonmutating set { viewModel.draft = newValue } }
    private var photo: PhotosPickerItem? { get { viewModel.photo } nonmutating set { viewModel.photo = newValue } }
    private var loadingPhoto: Bool { get { viewModel.loadingPhoto } nonmutating set { viewModel.loadingPhoto = newValue } }
    private var message: String? { get { viewModel.message } nonmutating set { viewModel.message = newValue } }
    private var loaded: Bool { get { viewModel.loaded } nonmutating set { viewModel.loaded = newValue } }
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                hero
                card {
                    sectionHeading("Personal information", icon: "person.text.rectangle")
                    field("LEGAL FULL NAME", text: $viewModel.draft.fullName, symbol: "person")
                    VStack(alignment: .leading, spacing: 6) {
                        field("DISPLAY NICKNAME", text: $viewModel.draft.nickname, symbol: "at")
                        Text("Visible on your household dashboard & chore board").font(.caption2).foregroundStyle(DashboardPalette.muted)
                    }
                    field("EMAIL ADDRESS", text: $viewModel.draft.email, symbol: "envelope", keyboard: .emailAddress)
                    VStack(alignment: .leading, spacing: 7) {
                        label("MOBILE PHONE")
                        HStack(spacing: 10) {
                            TextField("+94", text: $viewModel.draft.countryCode).keyboardType(.phonePad).textContentType(nil).frame(width: 56)
                            Rectangle().fill(Color.gray.opacity(0.2)).frame(width: 1, height: 20)
                            TextField("Phone number", text: $viewModel.draft.phone).keyboardType(.phonePad).textContentType(nil)
                            Image(systemName: "phone").foregroundStyle(DashboardPalette.muted)
                        }.font(.subheadline .weight(.medium)).padding(14).background(inputBackground, in: RoundedRectangle(cornerRadius: 12)).overlay(inputBorder)
                        Text("For +94 enter 0771234567 or 771234567. Phone is optional.").font(.caption).foregroundStyle(.secondary)
                        if !viewModel.validMobile {
                            Text("Check the country code and mobile number.").font(.caption).foregroundStyle(.red)
                        }
                    }
                }
                card {
                    sectionHeading("Security & identification", icon: "lock.shield")
                    VStack(alignment: .leading, spacing: 7) {
                        label("NIC NUMBER (OPTIONAL)")
                        HStack {
                            Group { if showNIC { TextField("National identity number", text: $viewModel.draft.nic) } else { SecureField("National identity number", text: $viewModel.draft.nic) } }
                                .font(.system(size: 13, design: .monospaced)).textInputAutocapitalization(.characters).autocorrectionDisabled()
                            Button { showNIC.toggle() } label: { Image(systemName: showNIC ? "eye.slash" : "eye") }.accessibilityLabel(showNIC ? "Hide identity number" : "Show identity number")
                        }.padding(14).background(inputBackground, in: RoundedRectangle(cornerRadius: 12)).overlay(inputBorder)
                        Text("Stored locally with your profile. Not used to verify your identity.").font(.caption2).foregroundStyle(DashboardPalette.muted)
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        label("HOUSEHOLD ROLE")
                        HStack {
                            Image(systemName: "person.badge.shield.checkmark").foregroundStyle(green)
                            Text("Member").font(.subheadline .weight(.semibold))
                            Spacer()
                            Text("LOCAL PROFILE").font(.caption2 .weight(.semibold)).padding(6).background(green.opacity(0.08), in: Capsule())
                        }.padding(12).background(inputBackground, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                card {
                    sectionHeading("Household sharing", icon: "person.2")
                    HStack(spacing: 12) {
                        Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(green)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Live status sharing").font(.subheadline .weight(.semibold))
                            Text("Not available in local mode").font(.caption2).foregroundStyle(DashboardPalette.muted)
                        }
                        Spacer()
                        Toggle("Live status sharing", isOn: .constant(false)).labelsHidden().disabled(true).scaleEffect(0.8, anchor: .trailing)
                    }
                    Button { editEmergency = true } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "cross.case").foregroundStyle(.orange).frame(width: 32, height: 32).background(.orange.opacity(0.08), in: Circle())
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Emergency contact").font(.caption .weight(.semibold))
                                Text(draft.emergencyName.isEmpty ? "Add a trusted contact" : "\(draft.emergencyName) · \(draft.emergencyPhone)").font(.caption).foregroundStyle(DashboardPalette.muted)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "square.and.pencil").font(.subheadline)
                        }.padding(12).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.orange.opacity(0.2)))
                    }.buttonStyle(.plain)
                }
                VStack(spacing: 10) {
                    if let message { Text(message).font(.caption).foregroundStyle(.red) }
                    Button { if viewModel.save() { dismiss() } } label: { Label("Save changes", systemImage: "checkmark").font(.body .weight(.semibold)).frame(maxWidth: .infinity).frame(height: 48).foregroundStyle(.white).background(DashboardPalette.brandFill, in: RoundedRectangle(cornerRadius: 16)).shadow(color: green.opacity(0.2), radius: 4, y: 3) }
                        .disabled(!viewModel.canSave)
                    Button("Cancel") { dismiss() }.font(.subheadline .weight(.semibold)).frame(maxWidth: .infinity).frame(height: 44).foregroundStyle(DashboardPalette.muted)
                }.padding(.top, 8).padding(.bottom, 24)
            }.padding(.horizontal, 20).padding(.top, 23).frame(maxWidth: 680).frame(maxWidth: .infinity)
        }.background(HomeBackdrop()).foregroundStyle(DashboardPalette.ink)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack {
                    Button { dismiss() } label: { Image(systemName: "chevron.left").font(.title3).frame(width: 40, height: 44) }.accessibilityLabel("Cancel and return to Settings")
                    Spacer()
                    Text("Profile Settings").font(.headline .weight(.bold))
                    Spacer()
                    Color.clear.frame(width: 40, height: 44)
                }.padding(.horizontal, 8).frame(height: 56).background(HomeMateStyle.background.opacity(0.95)).overlay(alignment: .bottom) { Color.gray.opacity(0.12).frame(height: 1) }
            }
            .onAppear { viewModel.loadIfNeeded() }
            .onChange(of: photo) { _, selection in Task { await viewModel.loadPhoto(selection) } }
            .sheet(isPresented: $editEmergency) {
                NavigationStack {
                    Form { TextField("Contact name", text: $viewModel.draft.emergencyName).exactTextEntry(); TextField("Phone number", text: $viewModel.draft.emergencyPhone).keyboardType(.phonePad); if !viewModel.validEmergencyPhone { Text("Enter 7–15 digits, with an optional + at the beginning.").foregroundStyle(.red) }; Text("Saved only when you save your profile.").font(.caption) }
                        .navigationTitle("Emergency contact").navigationBarTitleDisplayMode(.inline).toolbar { Button("Done") { editEmergency = false }.disabled(!viewModel.validEmergencyPhone) }
                }
            }
            .interactiveDismissDisabled()
    }
    private var hero: some View {
        VStack(spacing: 10) {
            ProfileAvatar(data: draft.avatarData, name: draft.nickname.isEmpty ? draft.fullName : draft.nickname, size: 88)
                .padding(5).background(green.opacity(0.08), in: Circle())
                .overlay(alignment: .bottomTrailing) {
                    PhotosPicker(selection: $viewModel.photo, matching: .images) {
                        Image(systemName: "camera.fill").font(.footnote).foregroundStyle(.white).frame(width: 32, height: 32).background(DashboardPalette.brandFill, in: Circle()).overlay(Circle().stroke(.white, lineWidth: 2))
                    }.accessibilityLabel("Choose profile photo")
                }
            if loadingPhoto { ProgressView() }
            Text(draft.nickname.isEmpty ? draft.fullName : draft.nickname).font(.headline .weight(.bold))
            Label(viewModel.profile.household, systemImage: "house.fill").font(.caption2 .weight(.bold)).foregroundStyle(green).padding(.horizontal, 10).padding(.vertical, 5).background(green.opacity(0.07), in: Capsule())
            Text("Make yourself at home.").font(.caption).foregroundStyle(DashboardPalette.muted)
        }.padding(20).frame(maxWidth: .infinity).frame(minHeight: 265)
            .background(alignment: .topTrailing) { Circle().fill(green.opacity(0.05)).frame(width: 128, height: 128).offset(x: 47, y: -47) }
            .background(alignment: .bottomLeading) { Circle().fill(DashboardPalette.mint.opacity(0.2)).frame(width: 112, height: 112).offset(x: -39, y: 39) }
            .background(Color(uiColor: .secondarySystemGroupedBackground)).clipShape(RoundedRectangle(cornerRadius: 24)).overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.gray.opacity(0.12)))
            .shadow(color: DashboardPalette.green.opacity(0.055), radius: 12, y: 5)
    }
    private var inputBackground: Color { Color(uiColor: .tertiarySystemGroupedBackground) }
    private var inputBorder: some View { RoundedRectangle(cornerRadius: 12).stroke(Color.gray.opacity(0.15)) }
    private func label(_ title: String) -> some View { Text(title).font(.caption2 .weight(.bold)).tracking(0.4).foregroundStyle(DashboardPalette.muted) }
    private func field(_ title: String, text: Binding<String>, symbol: String, keyboard: UIKeyboardType = .default) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            label(title)
            HStack {
                TextField(title.capitalized, text: text).keyboardType(keyboard).exactTextEntry()
                Image(systemName: symbol).foregroundStyle(DashboardPalette.muted)
            }.font(.subheadline .weight(.medium)).padding(14).background(inputBackground, in: RoundedRectangle(cornerRadius: 12)).overlay(inputBorder)
        }
    }
    private func sectionHeading(_ title: String, icon: String) -> some View {
        VStack(spacing: 8) { HStack(spacing: 8) { Image(systemName: icon).foregroundStyle(green); Text(title).font(.body .weight(.bold)); Spacer() }; Color.gray.opacity(0.1).frame(height: 1) }
    }
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14, content: content).padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24)).overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.gray.opacity(0.12))).shadow(color: .black.opacity(0.05), radius: 1, y: 1)
    }

}
