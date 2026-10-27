import SwiftUI

// One small visual vocabulary, shared by all screens.
struct HomeBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack(alignment: .topTrailing) {
            HomeMateStyle.background
            Circle().fill(DashboardPalette.mint.opacity(scheme == .dark ? 0.045 : 0.2))
                .frame(width: 300, height: 300).blur(radius: 80).offset(x: 150, y: -150)
        }.ignoresSafeArea()
    }
}

struct HomeHeroSurface: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.07, green: 0.22, blue: 0.21), Color(red: 0.035, green: 0.12, blue: 0.14)], startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(alignment: .topTrailing) {
                Circle().stroke(.white.opacity(0.055), lineWidth: 36).frame(width: 210, height: 210).offset(x: 70, y: -95)
            }
            .overlay(alignment: .bottomTrailing) {
                Circle().fill(DashboardPalette.mint.opacity(0.12)).frame(width: 140, height: 140).blur(radius: 35).offset(x: 30, y: 50)
            }
            .allowsHitTesting(false)
    }
}
struct HomePressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}
struct HomePrimaryButton: View {
    var title: String
    var icon = "plus"
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.body .weight(.semibold))
                .frame(maxWidth: .infinity).frame(minHeight: 52)
                .foregroundStyle(.white)
                .background(DashboardPalette.brandFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: DashboardPalette.green.opacity(0.10), radius: 6, y: 3)
        }.buttonStyle(HomePressStyle())
    }
}
struct HomeSectionTitle: View {
    var eyebrow: String
    var title: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(eyebrow.uppercased()).font(.caption2 .weight(.bold)).tracking(1.8).foregroundStyle(DashboardPalette.green)
            Text(title).font(.title .weight(.bold)).tracking(-0.8).foregroundStyle(DashboardPalette.ink)
        }
    }
}
extension View {
    func homeCard(cornerRadius: CGFloat = 24) -> some View {
        self.background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(Color.primary.opacity(0.045), lineWidth: 1))
            .shadow(color: .black.opacity(0.025), radius: 10, x: 0, y: 4)
    }
}

private struct HomeContentWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 390
}
extension EnvironmentValues {
    var homeContentWidth: CGFloat {
        get { self[HomeContentWidthKey.self] }
        set { self[HomeContentWidthKey.self] = newValue }
    }
}
private struct HomeResponsiveContainer: ViewModifier {
    func body(content: Content) -> some View {
        GeometryReader { geometry in
            content.environment(\.homeContentWidth, geometry.size.width)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}
extension View {
    // Measure the actual detail pane, so rotation and iPad window resizing reflow content.
    func responsiveHomeWidth() -> some View { modifier(HomeResponsiveContainer()) }
}

struct AppLockContainer<Content: View>: View {
    @EnvironmentObject private var appLock: AppLockViewModel
    @Environment(\.scenePhase) private var phase
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            if !appLock.enabled || appLock.unlocked {
                content()
                    .allowsHitTesting(!appLock.enabled || phase == .active)
                    .accessibilityHidden(appLock.enabled && phase != .active)
            }
            if appLock.enabled && (!appLock.unlocked || phase != .active) {
                VStack(spacing: 28) {
                    HStack(spacing: 8) { Image(systemName: "house.lodge.fill"); Text("HomeMate").fontWeight(.bold) }
                        .font(.title3).foregroundStyle(DashboardPalette.green)
                    Spacer()
                    Image(systemName: "faceid").font(.system(size: 64, weight: .ultraLight))
                        .foregroundStyle(DashboardPalette.mint).frame(width: 144, height: 144)
                        .background { HomeHeroSurface().clipShape(RoundedRectangle(cornerRadius: 44)) }
                        .shadow(color: DashboardPalette.green.opacity(0.22), radius: 24, y: 14)
                    VStack(spacing: 8) {
                        Text("Your home.\nYour private space.").font(.largeTitle.bold()).tracking(-1.2).multilineTextAlignment(.center)
                        Text("A little peace of mind, every time you return.").font(.body).foregroundStyle(.secondary)
                    }
                    Button { Task { await appLock.unlock() } } label: {
                        Label("Unlock HomeMate", systemImage: "faceid").frame(minHeight: 44)
                    }.buttonStyle(.borderedProminent).controlSize(.large).buttonBorderShape(.capsule).disabled(appLock.busy)
                    if appLock.busy { ProgressView().accessibilityLabel("Authenticating") }
                    if let message = appLock.message { Text(message).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                    Spacer()
                    Label("Protected with biometrics", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
                }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(HomeBackdrop())
            }
        }
        .task { if phase == .active { await appLock.unlock() } }
        .onChange(of: phase) { _, current in
            if current == .background { appLock.lock() }
            // Authentication itself can make the scene inactive. Only retry on explicit tap
            // after a cancellation, so returning from the system prompt never loops.
        }
    }
}

// Names and other exact text must retain the user's spelling and case.
extension View {
    func exactTextEntry() -> some View {
        self.autocorrectionDisabled(true).textInputAutocapitalization(.never).textContentType(nil)
    }
}

// Apply the saved preference at each presentation that can change it live.
// Sheets have their own preferred-colour-scheme boundary.
private struct HomeAppearance: ViewModifier {
    @AppStorage("appearance") private var appearance = "system"
    func body(content: Content) -> some View {
        content.preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
    }
}
extension View {
    func homeAppearance() -> some View { modifier(HomeAppearance()) }
}
