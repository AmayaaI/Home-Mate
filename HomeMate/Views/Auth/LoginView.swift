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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
            let wide = geometry.size.width >= 850 && !dynamicTypeSize.isAccessibilitySize
            let panelHeight = max(560, min(760, geometry.size.height - 48))
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        if onContinueOffline == nil {
                            HStack { Button { dismiss() } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }.accessibilityLabel("Back"); Spacer() }.frame(maxWidth: .infinity)
                        }
                        if wide {
                            HStack(spacing: 20) {
                                brand(wide: true)
                                    .frame(width: (geometry.size.width - 68) * 0.57)
                                formContent(wide: true, minimumHeight: panelHeight)
                                    .frame(maxWidth: .infinity)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                        } else {
                            VStack(spacing: 20) { brand(wide: false); formContent(wide: false) }.frame(maxWidth: 560).padding(.vertical, 20)
                        }
                    }
                    .id("auth-top")
                    .padding(.horizontal, 24).frame(maxWidth: .infinity).frame(minHeight: geometry.size.height, alignment: wide ? .center : .top)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: registering) { _, _ in
                    focused = nil
                    withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo("auth-top", anchor: .top) }
                }
                .background(HomeBackdrop().ignoresSafeArea())
            }
        }.foregroundStyle(DashboardPalette.ink).toolbar(.hidden, for: .navigationBar)
            .toolbar(.hidden, for: .tabBar)
            .sheet(isPresented: $showReset) { PasswordResetView() }
            .alert("Unable to continue", isPresented: $viewModel.showingError) {
                Button("OK", role: .cancel) {}
            } message: { Text(localError ?? viewModel.accountMessage) }
            .onChange(of: viewModel.accountSignedIn) { _, signedIn in if signedIn && onContinueOffline == nil { dismiss() } }
    }
    private func brand(wide: Bool) -> some View {
        Group {
            if wide {
                VStack(alignment: .leading, spacing: 20) {
                    Label("Made for your household", systemImage: "house")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(HomeMateStyle.card.opacity(0.85), in: Capsule())
                    brandCopy(wide: true)
                    Spacer(minLength: 260)
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background {
                    GeometryReader { geometry in
                        Image("AuthWelcome")
                            .resizable().scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottom)
                            .clipped()
                            .overlay(Color.black.opacity(colorScheme == .dark ? 0.25 : 0))
                            .overlay(alignment: .top) {
                                LinearGradient(colors: [HomeMateStyle.card.opacity(0.97), HomeMateStyle.card.opacity(0.80), .clear], startPoint: .top, endPoint: .bottom)
                                    .frame(height: geometry.size.height * 0.42)
                            }
                    }.accessibilityHidden(true)
                }
            } else {
                HStack(spacing: 0) {
                    brandCopy(wide: false)
                        .padding(.leading, 22).padding(.vertical, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !dynamicTypeSize.isAccessibilitySize {
                        Image("AuthWelcome")
                            .resizable().scaledToFit()
                            .frame(width: 144)
                            .overlay(Color.black.opacity(colorScheme == .dark ? 0.20 : 0))
                            .accessibilityHidden(true)
                    }
                }
                .padding(.trailing, dynamicTypeSize.isAccessibilitySize ? 22 : 0)
                .frame(maxWidth: .infinity)
                .background(colorScheme == .dark ? HomeMateStyle.card : Color(red: 0.98, green: 0.98, blue: 0.95))
            }
        }
        .foregroundStyle(DashboardPalette.green)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Color.primary.opacity(0.04)))
        .shadow(color: .black.opacity(0.06), radius: 16, y: 10)
    }

    private func brandCopy(wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: wide ? 12 : 10) {
            Text("HomeMate")
                .font(wide ? .largeTitle.bold() : .title2.bold()).tracking(-0.8)
                .accessibilityAddTraits(.isHeader)
            Text(registering ? "Good things start at home." : "Less life admin. More living.")
                .font(wide ? .title3.weight(.semibold) : .subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if wide {
                Text("Your household routines, bills and family plans.\nTogether in one happy place.")
                    .font(.subheadline).foregroundStyle(.primary.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private var authTeal: Color { Color(red: 20 / 255, green: 95 / 255, blue: 87 / 255) }

    private func formContent(wide: Bool, minimumHeight: CGFloat = 0) -> some View {
        VStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text(registering ? "Create your account" : "Welcome Back").font(.title2.bold()).tracking(-0.7)
                Text(registering ? "Make room for a more organised day." : "Sign in to access household routines, budgets and family plans.").font(.subheadline).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if wide { Spacer(minLength: 0) }
            VStack(spacing: 20) {
                inputCard(icon: "envelope", label: "Email Address", active: focused == .email) {
                    TextField("you@example.com", text: $viewModel.accountEmail).accessibilityLabel("Email address").keyboardType(.emailAddress).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled().focused($focused, equals: .email).submitLabel(.next).onSubmit { focused = .password }
                }
                inputCard(icon: "lock", label: "Password", active: focused == .password) {
                    HStack {
                        Group {
                            if showPassword { TextField("Enter your password", text: $viewModel.accountPassword) }
                            else { SecureField("Enter your password", text: $viewModel.accountPassword) }
                        }.accessibilityLabel("Password").textContentType(registering ? .newPassword : .password).textInputAutocapitalization(.never).autocorrectionDisabled().focused($focused, equals: .password).submitLabel(registering ? .next : .go).onSubmit { if registering { focused = .confirmation } else { submit() } }
                        Button { showPassword.toggle() } label: { Image(systemName: showPassword ? "eye.slash" : "eye").frame(width: 32, height: 36).foregroundStyle(DashboardPalette.muted) }.accessibilityLabel(showPassword ? "Hide password" : "Show password")
                    }
                }
                if registering {
                    inputCard(icon: "lock.shield", label: "Confirm Password", active: focused == .confirmation) {
                        SecureField("Repeat your password", text: $viewModel.confirmation).accessibilityLabel("Confirm password").textContentType(.newPassword).focused($focused, equals: .confirmation).submitLabel(.go).onSubmit(submit)
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
                    }.frame(maxWidth: .infinity).frame(minHeight: 52).foregroundStyle(.white).background(authTeal, in: RoundedRectangle(cornerRadius: 12)).shadow(color: authTeal.opacity(0.16), radius: 8, y: 4)
                }.buttonStyle(HomePressStyle()).disabled(viewModel.accountBusy)
            }
            if wide { Spacer(minLength: 0) }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 5) { accountSwitch }
                VStack(spacing: 8) { accountSwitch }
            }.font(.subheadline)
            if !viewModel.accountConfigured { Text("Cloud sign-in is not connected yet. You can still use HomeMate on this device.").font(.caption).foregroundStyle(DashboardPalette.muted).multilineTextAlignment(.center) }
            if let onContinueOffline {
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        Rectangle().fill(Color.primary.opacity(0.10)).frame(height: 1)
                        Text("ON THIS DEVICE").font(.caption2).tracking(1).foregroundStyle(.secondary).fixedSize()
                        Rectangle().fill(Color.primary.opacity(0.10)).frame(height: 1)
                    }.accessibilityHidden(true)
                    Button(action: onContinueOffline) {
                        Label("Use offline household", systemImage: "house")
                            .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
                            .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(HomePressStyle())
                    Text("Offline mode is shared on this device. Sign in to keep your household separate.").font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
        }
        .padding(wide ? 24 : 22)
        .frame(minHeight: minimumHeight)
        .background(HomeMateStyle.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 16, y: 10)
        .tint(DashboardPalette.green)
        .disabled(viewModel.accountBusy)
    }
    @ViewBuilder private var accountSwitch: some View {
                Text(registering ? "Already have an account?" : "New to HomeMate?").foregroundStyle(DashboardPalette.muted)
                Button(registering ? "Log in" : "Create account") {
                    withAnimation(.easeInOut(duration: 0.2)) { viewModel.switchMode() }
                    // Keep the new screen anchored at its header; the user can opt into the keyboard by tapping a field.
                    focused = nil
                }.fontWeight(.semibold)
    }
    private func inputCard<Content: View>(icon: String, label: String, active: Bool, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.caption.weight(.semibold))
            HStack(spacing: 10) {
                Image(systemName: icon).font(.body).foregroundStyle(.secondary).frame(width: 20).accessibilityHidden(true)
                content().font(.body)
            }.padding(.horizontal, 14).padding(.vertical, 8).frame(minHeight: 48)
                .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(active ? DashboardPalette.green.opacity(0.5) : .clear, lineWidth: 1))
        }
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
