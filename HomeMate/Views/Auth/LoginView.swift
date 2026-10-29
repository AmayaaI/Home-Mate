import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var dependencies: AppDependencies
    var onContinueOffline: (() -> Void)? = nil

    var body: some View {
        ViewModelHost(make: LoginViewModel(store: dependencies.store, account: dependencies.account)) { model in
            LoginViewScreen(onContinueOffline: onContinueOffline, viewModel: model)
        }.id(dependencies.account.dataScope)
    }
}

private struct LoginViewScreen: View {

    @Environment(\.dismiss) private var dismiss
    var onContinueOffline: (() -> Void)? = nil

    @State private var showPassword = false

    @State private var showReset = false


    @FocusState private var focused: Field?
    private enum Field: Hashable { case email, password, confirmation }

    @ObservedObject var viewModel: LoginViewModel
    private var registering: Bool { get { viewModel.registering } nonmutating set { viewModel.registering = newValue } }
    private var confirmation: String { get { viewModel.confirmation } nonmutating set { viewModel.confirmation = newValue } }
    private var showingError: Bool { get { viewModel.showingError } nonmutating set { viewModel.showingError = newValue } }
    private var localError: String? { get { viewModel.localError } nonmutating set { viewModel.localError = newValue } }
    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 700
            ScrollView {
                VStack(spacing: 0) {
                    if onContinueOffline == nil {
                        HStack { Button { dismiss() } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }.accessibilityLabel("Back"); Spacer() }.frame(maxWidth: 1000)
                    }
                    if wide {
                        HStack(spacing: 36) { brand(wide: true).frame(maxWidth: 380); formContent(compact: true).frame(maxWidth: 430) }.frame(maxWidth: 1000).padding(.vertical, 24)
                    } else {
                        VStack(spacing: 22) { brand(wide: false); formContent(compact: false) }.frame(maxWidth: 430).padding(.vertical, 20)
                    }
                }.padding(.horizontal, 24).frame(maxWidth: .infinity).frame(minHeight: geometry.size.height, alignment: wide ? .center : .top)
            }.scrollDismissesKeyboard(.interactively).background(HomeBackdrop().ignoresSafeArea())
        }.foregroundStyle(DashboardPalette.ink).toolbar(.hidden, for: .navigationBar)
            .toolbar(.hidden, for: .tabBar)
            .sheet(isPresented: $showReset) { PasswordResetView() }
            .alert("Unable to continue", isPresented: $viewModel.showingError) {
                Button("OK", role: .cancel) {}
            } message: { Text(localError ?? viewModel.accountMessage) }
            .onChange(of: viewModel.accountSignedIn) { _, signedIn in if signedIn && onContinueOffline == nil { dismiss() } }
    }
    private func brand(wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: wide ? 16 : 22) {
            HStack(spacing: 10) {
                Image(systemName: "house.lodge.fill").font(.title2).foregroundStyle(DashboardPalette.mint)
                Text("HomeMate").font(.title3.bold()).foregroundStyle(.white)
                Spacer()
            }
            Text(registering ? "Good things\nstart at home." : "Less life admin.\nMore living.")
                .font(.system(wide ? .title : .largeTitle, design: .rounded, weight: .bold)).tracking(-1.2).foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Text(registering ? "Your people. Your plans. One happy place." : "Your household, beautifully in sync.")
                .font(.subheadline).foregroundStyle(.white.opacity(0.7))
            HStack(spacing: 8) {
                ForEach(["Plan together", "Spend smarter"], id: \.self) { text in
                    Text(text).font(.caption2.weight(.medium)).padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.white.opacity(0.1), in: Capsule()).foregroundStyle(DashboardPalette.mint)
                }
            }
        }.padding(wide ? 22 : 26).frame(maxWidth: .infinity, alignment: .leading)
            .background { HomeHeroSurface() }.clipShape(RoundedRectangle(cornerRadius: 30))
    }
    private func formContent(compact: Bool) -> some View {
        VStack(spacing: compact ? 14 : 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text(registering ? "Create your account" : "Welcome home").font(.title2.bold()).tracking(-0.7)
                Text(registering ? "Make room for a more organised day." : "Sign in and pick up where you left off.").font(.subheadline).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: compact ? 12 : 18) {
                inputCard(icon: "envelope", label: "EMAIL ADDRESS", active: focused == .email) {
                    TextField("you@example.com", text: $viewModel.accountEmail).keyboardType(.emailAddress).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled().focused($focused, equals: .email).submitLabel(.next).onSubmit { focused = .password }
                }
                inputCard(icon: "lock", label: "PASSWORD", active: focused == .password) {
                    HStack {
                        Group {
                            if showPassword { TextField("Enter your password", text: $viewModel.accountPassword) }
                            else { SecureField("Enter your password", text: $viewModel.accountPassword) }
                        }.textContentType(registering ? .newPassword : .password).textInputAutocapitalization(.never).autocorrectionDisabled().focused($focused, equals: .password).submitLabel(registering ? .next : .go).onSubmit { if registering { focused = .confirmation } else { submit() } }
                        Button { showPassword.toggle() } label: { Image(systemName: showPassword ? "eye.slash" : "eye").frame(width: 32, height: 36).foregroundStyle(DashboardPalette.muted) }.accessibilityLabel(showPassword ? "Hide password" : "Show password")
                    }
                }
                if registering {
                    inputCard(icon: "lock.shield", label: "CONFIRM PASSWORD", active: focused == .confirmation) {
                        SecureField("Repeat your password", text: $viewModel.confirmation).textContentType(.newPassword).focused($focused, equals: .confirmation).submitLabel(.go).onSubmit(submit)
                    }
                }
                HStack {
                    Button { viewModel.accountRememberSession.toggle() } label: {
                        HStack(spacing: 8) { Image(systemName: viewModel.accountRememberSession ? "checkmark.square.fill" : "square").font(.headline); Text("Remember me").font(.caption) }
                    }.accessibilityValue(viewModel.accountRememberSession ? "On" : "Off")
                    Spacer(minLength: 8)
                    if !registering { Button("Forgot password?") { viewModel.accountMessage = ""; showReset = true }.font(.caption .weight(.semibold)) }
                }.foregroundStyle(DashboardPalette.green).padding(.horizontal, 4)
                if let localError { Text(localError).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading) }
                if !viewModel.accountMessage.isEmpty { Text(viewModel.accountMessage).font(.caption).foregroundStyle(viewModel.accountIsError ? .red : DashboardPalette.green).frame(maxWidth: .infinity, alignment: .leading) }
                Button(action: submit) {
                    HStack(spacing: 10) {
                        if viewModel.accountBusy { ProgressView().tint(.white) }
                        Text(registering ? "Create account" : "Log in").font(.body .weight(.semibold))
                        if !viewModel.accountBusy { Image(systemName: "arrow.right").font(.footnote .weight(.semibold)) }
                    }.frame(maxWidth: .infinity).frame(minHeight: 54).foregroundStyle(.white).background(DashboardPalette.brandFill, in: RoundedRectangle(cornerRadius: 18)).shadow(color: DashboardPalette.green.opacity(0.12), radius: 6, y: 4)
                }.buttonStyle(HomePressStyle()).disabled(viewModel.accountBusy)
            }
            HStack(spacing: 5) {
                Text(registering ? "Already have an account?" : "New to HomeMate?").foregroundStyle(DashboardPalette.muted)
                Button(registering ? "Log in" : "Create account") {
                    withAnimation(.easeInOut(duration: 0.2)) { viewModel.switchMode() }
                    focused = .email
                }.fontWeight(.semibold)
            }.font(.subheadline)
            if !viewModel.accountConfigured { Text("Cloud sign-in is not connected yet. You can still use HomeMate on this device.").font(.caption).foregroundStyle(DashboardPalette.muted).multilineTextAlignment(.center) }
            if let onContinueOffline {
                VStack(spacing: 8) {
                    Button("Use offline household", action: onContinueOffline).font(.caption.weight(.semibold)).padding(.vertical, 4)
                    Text("Offline mode is shared on this device. Sign in to keep your household separate.").font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
        }
        .padding(compact ? 16 : 22)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(DashboardPalette.green.opacity(0.10), lineWidth: 1))
        .shadow(color: .black.opacity(0.045), radius: 14, y: 6)
        .disabled(viewModel.accountBusy)
    }
    private func inputCard<Content: View>(icon: String, label: String, active: Bool, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.body).foregroundStyle(DashboardPalette.muted.opacity(0.7)).frame(width: 20)
            VStack(alignment: .leading, spacing: 4) { Text(label).font(.caption2 .weight(.semibold)).tracking(0.7).foregroundStyle(DashboardPalette.muted); content().font(.body) }
        }.padding(.horizontal, 14).padding(.vertical, 10).frame(minHeight: 60).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(active ? DashboardPalette.green.opacity(0.5) : .clear, lineWidth: 1)).shadow(color: .black.opacity(0.04), radius: 2, y: 1)
    }
    private func submit() {
        focused = nil
        Task { await viewModel.submit() }
    }
}

struct PasswordResetView: View {
    @EnvironmentObject private var dependencies: AppDependencies

    var body: some View {
        ViewModelHost(make: PasswordResetViewModel(store: dependencies.store, account: dependencies.account)) { model in
            PasswordResetViewScreen(viewModel: model)
        }.id(dependencies.account.dataScope)
    }
}

private struct PasswordResetViewScreen: View {

    @Environment(\.dismiss) private var dismiss

    @ObservedObject var viewModel: PasswordResetViewModel
    private var email: String { get { viewModel.email } nonmutating set { viewModel.email = newValue } }
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 22) {
                Image(systemName: "envelope.badge").font(.system(size: 40)).foregroundStyle(DashboardPalette.green)
                HomeSectionTitle(eyebrow: "Let's get you back in", title: "Reset your password")
                Text("Enter your account email. Firebase will email a link to choose a new password.").font(.subheadline).foregroundStyle(DashboardPalette.muted)
                TextField("Email address", text: $viewModel.email).keyboardType(.emailAddress).textContentType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled().padding(16).homeCard(cornerRadius: 14)
                HomePrimaryButton(title: viewModel.accountBusy ? "Sending…" : "Send reset link", icon: "envelope") { Task { await viewModel.send() } }.disabled(viewModel.accountBusy)
                if !viewModel.accountMessage.isEmpty { Text(viewModel.accountMessage).font(.footnote).foregroundStyle(viewModel.accountIsError ? .red : DashboardPalette.green) }
                Spacer()
            }.padding(24).frame(maxWidth: 500).frame(maxWidth: .infinity).background(HomeBackdrop()).navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Done") { dismiss() } }.onAppear { viewModel.prepare() }
        }
    }
}
