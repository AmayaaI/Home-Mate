import SwiftUI
import VisionKit
import PhotosUI

struct DocumentScanner: UIViewControllerRepresentable {
    var completion: (UIImage?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion) }
    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}
    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let completion: (UIImage?) -> Void
        init(_ completion: @escaping (UIImage?) -> Void) { self.completion = completion }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            completion(scan.pageCount > 0 ? scan.imageOfPage(at: 0) : nil)
        }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { completion(nil) }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { completion(nil) }
    }
}

struct ScanReviewView: View {
    @EnvironmentObject private var dependencies: AppDependencies
    var initialKind: RecordKind = .bill
    var body: some View {
        ViewModelHost(make: ScannerViewModel(store: dependencies.store, account: dependencies.account, initialKind: initialKind, context: dependencies.household)) { model in
            ScanReviewViewScreen(viewModel: model)
        }.id(dependencies.household.identity)
    }
}

private struct ScanReviewViewScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var camera = false
    @State private var showRawText = false
    @State private var shareBill: HouseholdRecord?
    @ObservedObject var viewModel: ScannerViewModel

    private let ink = DashboardPalette.ink
    private let green = DashboardPalette.green
    private let actionGreen = Color(red: 20.0 / 255, green: 95.0 / 255, blue: 87.0 / 255)
    private let muted = DashboardPalette.muted
    private let canvas = HomeMateStyle.background
    private let soft = DashboardPalette.surface

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if viewModel.text.isEmpty { startCard }
                    else {
                        successCard
                        recordTypePicker
                        fields
                        actions
                    }
                    if viewModel.busy { ProgressView("Reading bill on device…").frame(maxWidth: .infinity).padding() }
                    if let error = viewModel.error { Text(error).font(.footnote).foregroundStyle(.red).padding(.horizontal, 4) }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
            }
            .background(canvas.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $camera) {
                DocumentScanner { image in
                    camera = false
                    if let image { viewModel.recognize(image) }
                }
            }
            .sheet(isPresented: $showRawText) {
                ScannedTextReviewSheet(viewModel: viewModel)
                    .presentationCornerRadius(28)
                    .presentationDragIndicator(.visible)
            }
            .sheet(item: $viewModel.draft) { record in
                RecordEditor(record: record, onSaved: { dismiss() }, correctedModelCategory: viewModel.categoryWasEdited ? viewModel.modelSuggestedCategory : nil)
            }
            .sheet(item: $shareBill) { bill in
                NavigationStack {
                    ShareRecordWithFamilyView(record: bill)
                        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { shareBill = nil; dismiss() } } }
                }
            }
            .onChange(of: viewModel.photo) { _, item in Task { await viewModel.loadPhoto(item) } }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { dismiss() } label: { Label("Back", systemImage: "chevron.left") }
                .foregroundStyle(green)
            Spacer()
            VStack(spacing: 1) {
                Text(viewModel.text.isEmpty ? "Scan a bill or receipt" : viewModel.recordKind == .expense ? "Receipt OCR Result" : "Bill OCR Result")
                    .font(.system(size: 18, weight: .semibold))
                Text(viewModel.profile.household).font(.system(size: 11, weight: .semibold)).foregroundStyle(muted)
            }
            .foregroundStyle(ink)
            Spacer()
            Button("Cancel") { dismiss() }.foregroundStyle(Color(red: 186.0 / 255, green: 26.0 / 255, blue: 26.0 / 255))
        }
        .font(.system(size: 15, weight: .semibold))
        .frame(height: 48)
    }

    private var startCard: some View {
        VStack(spacing: 18) {
            Image(systemName: "doc.viewfinder").font(.system(size: 42, weight: .light)).foregroundStyle(green)
            Text("Scan a bill or receipt").font(.system(size: 20, weight: .bold)).foregroundStyle(ink)
            Text("Choose a photo or scan a paper bill. Select whether it is already paid or due later.")
                .font(.subheadline).foregroundStyle(muted).multilineTextAlignment(.center)
            if VNDocumentCameraViewController.isSupported {
                Button { camera = true } label: { Label("Scan with camera", systemImage: "camera.viewfinder").frame(maxWidth: .infinity).frame(height: 52) }
                    .buttonStyle(.plain).foregroundStyle(.white).background(actionGreen, in: RoundedRectangle(cornerRadius: 12))
            }
            PhotosPicker(selection: $viewModel.photo, matching: .images) {
                Label("Choose photo", systemImage: "photo").frame(maxWidth: .infinity).frame(height: 48)
            }
            .buttonStyle(.plain).foregroundStyle(green).background(soft, in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(22)
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var successCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark").font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 40, height: 40).background(actionGreen, in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text("Scan completed").font(.system(size: 18, weight: .semibold)).foregroundStyle(ink)
                    Text(viewModel.amountSourceLine != nil
                         ? "Total found. Check it against the photo."
                         : viewModel.parsedAmount != nil
                         ? "Amount entered manually. Check it against the photo."
                         : "Total not found. Enter it below.")
                        .font(.system(size: 13))
                        .foregroundStyle(viewModel.parsedAmount == nil ? .orange : muted)
                }
            }
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("TOTAL AMOUNT").font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(muted)
                    if let amount = viewModel.parsedAmount {
                        Text(viewModel.money(amount))
                            .font(.system(size: 27, weight: .bold, design: .rounded))
                            .foregroundStyle(ink)
                    } else {
                        Text("Needs review")
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
                Image(systemName: viewModel.parsedAmount == nil ? "exclamationmark.circle" : "checkmark.circle.fill")
                    .foregroundStyle(viewModel.parsedAmount == nil ? .orange : green)
            }
            .padding(14)
            .background(soft, in: RoundedRectangle(cornerRadius: 9))
            Button { showRawText = true } label: {
                HStack(spacing: 12) {
                    Group {
                        if let image = viewModel.scannedImage {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else {
                            Image(systemName: "doc.text").resizable().scaledToFit().padding(10).foregroundStyle(green)
                        }
                    }
                    .frame(width: 54, height: 54).clipped().background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Scanned text").font(.system(size: 14, weight: .semibold)).foregroundStyle(ink)
                        Text("Tap to read, copy or correct").font(.system(size: 12)).foregroundStyle(muted)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(green)
                }
                .padding(10).background(soft, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
        .billCard()
    }

    private var recordTypePicker: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("WHAT ARE YOU ADDING?").font(.system(size: 11, weight: .semibold)).tracking(0.55).foregroundStyle(muted)
            HStack(spacing: 8) {
                typeButton(.expense, title: "Already paid", detail: "Track spending", icon: "checkmark.circle")
                typeButton(.bill, title: "Pay later", detail: "Upcoming bill", icon: "calendar.badge.clock")
            }
            Text(viewModel.recordKind == .expense
                 ? "This receipt counts in spending for its purchase month."
                 : "This bill stays unpaid until you mark it paid; then it counts in spending.")
                .font(.system(size: 12)).foregroundStyle(muted)
        }
        .billCard()
    }

    private func typeButton(_ kind: RecordKind, title: String, detail: String, icon: String) -> some View {
        Button { viewModel.recordKind = kind } label: {
            VStack(alignment: .leading, spacing: 5) {
                Label(title, systemImage: icon).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 11))
            }
            .frame(maxWidth: .infinity, minHeight: 45, alignment: .leading)
            .padding(10)
            .background(viewModel.recordKind == kind ? green : soft, in: RoundedRectangle(cornerRadius: 9))
            .foregroundStyle(viewModel.recordKind == kind ? .white : ink)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(viewModel.recordKind == kind ? .isSelected : [])
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("EDITABLE DETECTED FIELDS").font(.system(size: 11, weight: .semibold)).tracking(0.55).foregroundStyle(muted)
                Spacer()
                Label("Check each field", systemImage: "checkmark.shield").font(.system(size: 12)).foregroundStyle(green)
            }.padding(.horizontal, 4).padding(.bottom, 2)
            fieldCard("PROVIDER", icon: "building.2", badge: "Detected") {
                TextField("Enter provider", text: $viewModel.provider)
                    .font(.system(size: 18, weight: .semibold)).foregroundStyle(ink).textInputAutocapitalization(.words)
            }
            fieldCard("TOTAL AMOUNT", icon: "banknote", badge: viewModel.amountSourceLine != nil ? "Detected" : viewModel.parsedAmount != nil ? "Entered" : "Enter manually") {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(viewModel.currency).font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4).background(soft, in: RoundedRectangle(cornerRadius: 6))
                    TextField("0.00", text: Binding(
                        get: { viewModel.amountText },
                        set: { viewModel.amountText = $0; viewModel.amountSourceLine = nil }
                    )).keyboardType(.decimalPad)
                        .font(.system(size: 28, weight: .bold)).foregroundStyle(ink)
                }
                if let source = viewModel.amountSourceLine {
                    Text("Read from: \(source)")
                        .font(.system(size: 12))
                        .foregroundStyle(muted)
                        .lineLimit(2)
                } else if viewModel.parsedAmount == nil {
                    Text("We could not identify a total. Type the price shown on the receipt.")
                        .font(.system(size: 12))
                        .foregroundStyle(muted)
                }
                if let split = viewModel.splitAmount, viewModel.splitMembers.count > 1 {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Label("Equal household split", systemImage: "person.3")
                            Spacer()
                            Text(viewModel.money(split) + " each")
                        }
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(green)
                        Text("Preview for \(viewModel.splitMembers.count) members; this does not create payments.")
                            .font(.system(size: 12)).foregroundStyle(muted)
                    }
                    .padding(10).background(soft, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            fieldCard(viewModel.recordKind == .expense ? "PURCHASE DATE" : "PAYMENT DUE DATE", icon: "calendar", badge: "Editable") {
                if viewModel.recordKind == .expense {
                    DatePicker("Purchase date", selection: $viewModel.purchaseDate, in: ...Date(), displayedComponents: .date).tint(green)
                } else {
                    DatePicker("Due date", selection: $viewModel.dueDate, in: Date()..., displayedComponents: .date).tint(green)
                }
            }
            fieldCard("REFERENCE NUMBER / ACCOUNT NO", icon: "number", badge: "Optional") {
                TextField("Enter reference number", text: $viewModel.reference)
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(ink).textInputAutocapitalization(.characters)
            }
            fieldCard("EXPENSE CATEGORY", icon: "tag", badge: viewModel.categoryWasEdited ? "Selected" : "Review") {
                categoryChips
                Text(viewModel.categorySuggestionMessage).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func fieldCard<Content: View>(_ title: String, icon: String, badge: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(green)
                Text(title).foregroundStyle(muted).tracking(0.55)
                Spacer()
                Text(badge).foregroundStyle(green).padding(.horizontal, 8).padding(.vertical, 3).background(soft, in: Capsule())
            }
            .font(.system(size: 11, weight: .semibold))
            content()
        }
        .billCard()
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ExpenseIntelligence.categories, id: \.self) { category in
                    Button(category) { viewModel.selectCategory(category) }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(viewModel.category == category ? .white : muted)
                        .padding(.horizontal, 13).padding(.vertical, 9)
                        .background(viewModel.category == category ? DashboardPalette.brandFill : soft, in: Capsule())
                }
            }
        }
    }

    private var householdCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("HOUSEHOLD SPLIT & NOTIFICATIONS", systemImage: "person.3.fill")
                .font(.system(size: 11, weight: .semibold)).tracking(0.55).foregroundStyle(muted)
            if viewModel.splitMembers.isEmpty {
                Text("Add household members in your profile to preview an equal split.")
                    .font(.system(size: 13)).foregroundStyle(muted)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(viewModel.splitMembers, id: \.self) { member in
                        VStack(spacing: 5) {
                            Text(String(member.prefix(1)).uppercased()).font(.system(size: 16, weight: .bold))
                                .frame(width: 34, height: 34).background(Color(uiColor: .secondarySystemGroupedBackground), in: Circle())
                            Text(member).lineLimit(1).font(.system(size: 12, weight: .medium))
                            if let split = viewModel.splitAmount {
                                Text(viewModel.money(split)).font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(green).lineLimit(1).minimumScaleFactor(0.7)
                            }
                        }
                        .frame(width: 78).padding(.vertical, 8).background(soft, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
            Toggle(isOn: $viewModel.notifyFamily) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Share with family after saving").font(.system(size: 15, weight: .semibold)).foregroundStyle(ink)
                    Text("Choose an accepted family in the next step.").font(.system(size: 12)).foregroundStyle(muted)
                }
            }
            .tint(green)
            .disabled(!viewModel.accountSignedIn || viewModel.sharedHousehold)
            if !viewModel.accountSignedIn {
                Text("Sign in to share this bill with family members.").font(.system(size: 12)).foregroundStyle(muted)
            }
        }
        .billCard()
    }

    private var actions: some View {
        VStack(spacing: 8) {
            if let problem = viewModel.scanValidationError {
                Text(problem).font(.system(size: 12)).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                viewModel.reviewVisibility()
            } label: {
                Label("Continue to visibility & save", systemImage: "arrow.right")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity).frame(height: 52)
            }
            .buttonStyle(.plain).foregroundStyle(.white).background(actionGreen, in: RoundedRectangle(cornerRadius: 12))
            .disabled(viewModel.scanValidationError != nil || viewModel.saving)
            Text("Choose Private or Shared in the next step before saving.").font(.caption)
            Text(viewModel.recordKind == .expense
                 ? "Review the store, amount and purchase date before saving."
                 : "Review the provider, amount and due date before saving.")
                .font(.system(size: 13)).foregroundStyle(muted).multilineTextAlignment(.center).padding(.horizontal, 16)
            HStack(spacing: 12) {
                PhotosPicker(selection: $viewModel.photo, matching: .images) {
                    Label("Choose photo", systemImage: "photo").frame(maxWidth: .infinity).frame(height: 44)
                }
                if VNDocumentCameraViewController.isSupported {
                    Button { camera = true } label: {
                        Label("Scan again", systemImage: "camera").frame(maxWidth: .infinity).frame(height: 44)
                    }
                } else {
                    Button { showRawText = true } label: {
                        Label("View text", systemImage: "doc.text").frame(maxWidth: .infinity).frame(height: 44)
                    }
                }
            }
            .font(.system(size: 12, weight: .medium)).buttonStyle(.plain).foregroundStyle(green)
            .background(soft, in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(.top, 8)
    }

}

private struct ScannedTextReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: ScannerViewModel
    @State private var isEditing = false
    @State private var draftText = ""
    @State private var copied = false
    @State private var showImage = false
    @FocusState private var editorFocused: Bool

    private let ink = DashboardPalette.ink
    private let green = DashboardPalette.green
    private let muted = DashboardPalette.muted
    private let canvas = HomeMateStyle.background
    private let soft = DashboardPalette.surface

    private var lines: [String] {
        viewModel.text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    titleBlock
                    detectedDetailsCard
                    if let image = viewModel.scannedImage { imagePreview(image) }
                    if isEditing { editorCard }
                    else { readableTextCard }
                }
                .padding(.horizontal, 18)
                .padding(.top, 24)
                .padding(.bottom, 24)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(canvas.ignoresSafeArea())
            .navigationTitle("Scanned text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(isEditing ? "Cancel" : "Done") {
                        if isEditing { isEditing = false; editorFocused = false }
                        else { dismiss() }
                    }
                    .foregroundStyle(green)
                }
                if !isEditing {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Edit text", systemImage: "pencil") {
                            draftText = viewModel.text
                            isEditing = true
                        }
                        .foregroundStyle(green)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { actionBar }
            .sheet(isPresented: $showImage) {
                if let image = viewModel.scannedImage {
                    NavigationStack {
                        ScrollView([.horizontal, .vertical]) {
                            Image(uiImage: image).resizable().scaledToFit()
                                .frame(maxWidth: .infinity)
                        }
                        .background(Color.black.ignoresSafeArea())
                        .navigationTitle("Original scan")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { showImage = false } } }
                    }
                }
            }
            .onAppear { draftText = viewModel.text }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isEditing ? "Correct the scan" : "Read the original text")
                .font(.system(size: 27, weight: .bold, design: .rounded))
                .tracking(-0.6)
                .foregroundStyle(ink)
            Text(isEditing
                 ? "Fix words or numbers that were read incorrectly. Apply your changes to refresh the detected fields."
                 : "Text was read on your device. Compare it with the photo before saving your expense or bill.")
                .font(.system(size: 14))
                .lineSpacing(4)
                .foregroundStyle(muted)
                .fixedSize(horizontal: false, vertical: true)
            Label("\(lines.count) lines detected", systemImage: "text.alignleft")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(green)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(green.opacity(0.08), in: Capsule())
                .padding(.top, 3)
        }
    }

    private var detectedDetailsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("DETECTED DETAILS", systemImage: "sparkle.magnifyingglass")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(green)
                Spacer()
                Text("Review before saving").font(.system(size: 11)).foregroundStyle(muted)
            }
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: viewModel.parsedAmount == nil ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 25))
                    .foregroundStyle(viewModel.parsedAmount == nil ? .orange : green)
                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.amountSourceLine != nil ? "Total price" : viewModel.parsedAmount != nil ? "Amount entered manually" : "Price not identified")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(muted)
                    if let amount = viewModel.parsedAmount {
                        Text(viewModel.money(amount))
                            .font(.system(size: 29, weight: .bold, design: .rounded))
                            .foregroundStyle(ink)
                    } else {
                        Text("Enter the amount in the review form")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(ink)
                    }
                    if let source = viewModel.amountSourceLine {
                        Text("From: \(source)")
                            .font(.system(size: 12))
                            .foregroundStyle(muted)
                    }
                }
            }
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "storefront").foregroundStyle(green)
                Text("Provider").foregroundStyle(muted)
                Spacer()
                Text(viewModel.provider.isEmpty ? "Check manually" : viewModel.provider)
                    .foregroundStyle(ink)
                    .lineLimit(1)
            }
            .font(.system(size: 13))
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(green.opacity(0.08)))
    }

    private func imagePreview(_ image: UIImage) -> some View {
        Button { showImage = true } label: {
            HStack(spacing: 14) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 66, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 5) {
                    Text("Original photo").font(.system(size: 15, weight: .semibold)).foregroundStyle(ink)
                    Text("Tap to compare with scanned text")
                        .font(.system(size: 12)).foregroundStyle(muted)
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(green)
            }
            .padding(10)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(green.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    private var readableTextCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("TEXT FROM SCAN", systemImage: "doc.text.viewfinder")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(green)
                Spacer()
                Text("Select to copy")
                    .font(.system(size: 11))
                    .foregroundStyle(muted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            Divider()
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .top, spacing: 12) {
                        Text(String(format: "%02d", index + 1))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(muted.opacity(0.75))
                            .frame(width: 24, alignment: .trailing)
                            .padding(.top, 3)
                        Text(line)
                            .font(.system(size: 16, weight: lineWeight(line)))
                            .lineSpacing(5)
                            .foregroundStyle(ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    if index != lines.count - 1 {
                        Divider().padding(.leading, 52)
                    }
                }
            }
            if lines.isEmpty {
                Text("No text is available. Scan the document again.")
                    .font(.subheadline).foregroundStyle(muted).padding(18)
            }
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(green.opacity(0.08)))
    }

    private func lineWeight(_ line: String) -> Font.Weight {
        let lower = line.lowercased()
        return lower.contains("total") || lower.contains("amount due") ? .semibold : .regular
    }

    private var editorCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("EDIT SCANNED TEXT", systemImage: "pencil.line")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(green)
            TextEditor(text: $draftText)
                .focused($editorFocused)
                .font(.system(size: 16))
                .foregroundStyle(ink)
                .lineSpacing(5)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 350)
                .padding(8)
                .background(soft, in: RoundedRectangle(cornerRadius: 10))
            Text("\(draftText.count) / 10,000 characters")
                .font(.system(size: 12))
                .foregroundStyle(draftText.count > 10_000 ? .red : muted)
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var actionBar: some View {
        VStack(spacing: 9) {
            if isEditing {
                Button {
                    viewModel.applyEditedText(draftText)
                    if viewModel.error == nil {
                        editorFocused = false
                        dismiss()
                    }
                } label: {
                    Label("Apply text & refresh fields", systemImage: "checkmark")
                        .frame(maxWidth: .infinity).frame(height: 50)
                }
                .disabled(draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draftText.count > 10_000)
            } else {
                Button {
                    UIPasteboard.general.string = viewModel.text
                    copied = true
                } label: {
                    Label(copied ? "Copied to clipboard" : "Copy all text", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity).frame(height: 50)
                }
            }
        }
        .font(.system(size: 15, weight: .semibold))
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(DashboardPalette.brandFill, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(canvas)
    }
}

private extension View {
    func billCard() -> some View {
        self.padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
    }
}
