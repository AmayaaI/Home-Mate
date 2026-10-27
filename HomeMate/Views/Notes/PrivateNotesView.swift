import SwiftUI
import PhotosUI
import AVFoundation

struct FamilyChatView: View {
    @EnvironmentObject private var dependencies: AppDependencies

    var body: some View {
        ViewModelHost(make: PrivateNotesViewModel(store: dependencies.store, account: dependencies.account)) { model in
            FamilyChatViewScreen(viewModel: model)
        }.id(dependencies.account.dataScope)
    }
}

private struct FamilyChatViewScreen: View {

    @Environment(\.homeContentWidth) private var contentWidth
    @Environment(\.dismiss) private var dismiss
    private var audio: ChatAudio { viewModel.audio }






    @State private var showRecords = false
    @State private var showDetails = false

    @State private var editingRecord: HouseholdRecord?
    @State private var focusedMessage: UUID?

    @FocusState private var composing: Bool
    private let green = DashboardPalette.green


    @ObservedObject var viewModel: PrivateNotesViewModel
    private var text: String { get { viewModel.text } nonmutating set { viewModel.text = newValue } }
    private var reply: ChatMessage? { get { viewModel.reply } nonmutating set { viewModel.reply = newValue } }
    private var selectedPhoto: PhotosPickerItem? { get { viewModel.selectedPhoto } nonmutating set { viewModel.selectedPhoto = newValue } }
    private var photoData: Data? { get { viewModel.photoData } nonmutating set { viewModel.photoData = newValue } }
    private var voiceFile: String? { get { viewModel.voiceFile } nonmutating set { viewModel.voiceFile = newValue } }
    private var linkedRecord: HouseholdRecord? { get { viewModel.linkedRecord } nonmutating set { viewModel.linkedRecord = newValue } }
    private var loadingPhoto: Bool { get { viewModel.loadingPhoto } nonmutating set { viewModel.loadingPhoto = newValue } }
    private var error: String? { get { viewModel.error } nonmutating set { viewModel.error = newValue } }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    contextBanner
                    if viewModel.personalMessages.isEmpty { emptyState }
                    ForEach(viewModel.days, id: \.self) { day in
                        HStack(spacing: 12) {
                            Rectangle().fill(Color.gray.opacity(0.15)).frame(height: 1)
                            Text(dayLabel(day)).font(.caption2 .weight(.semibold)).tracking(0.3).fixedSize().foregroundStyle(DashboardPalette.muted)
                            Rectangle().fill(Color.gray.opacity(0.15)).frame(height: 1)
                        }.padding(.vertical, 8)
                        ForEach(viewModel.personalMessages.filter { Calendar.current.isDate($0.date, inSameDayAs: day) }) { message in
                            messageRow(message).id(message.id)
                        }
                    }
                    Label("Saved on this device", systemImage: "lock").font(.caption2).foregroundStyle(DashboardPalette.muted).padding(.vertical, 8)
                    Color.clear.frame(height: 1).id("bottom")
                }.padding(.horizontal, 20).padding(.vertical, 16).frame(maxWidth: 900).frame(maxWidth: .infinity)
            }.scrollDismissesKeyboard(.interactively)
                .background(HomeBackdrop())
                .safeAreaInset(edge: .top, spacing: 0) { header }
                .safeAreaInset(edge: .bottom, spacing: 0) { composer }
                .toolbar(.hidden, for: .navigationBar)
                .foregroundStyle(DashboardPalette.ink)
                .onChange(of: viewModel.personalMessages.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: composing) { _, active in if active { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } } }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
        .sheet(isPresented: $showRecords) {
            NavigationStack {
                List(viewModel.personalRecords) { record in Button { linkedRecord = record; showRecords = false } label: { RecordRow(record: record) } }
                    .overlay { if viewModel.personalRecords.isEmpty { ContentUnavailableView("No records yet", systemImage: "doc.text", description: Text("Add a bill or task before linking it to a message.")) } }
                    .navigationTitle("Link a household record").navigationBarTitleDisplayMode(.inline).toolbar { Button("Cancel") { showRecords = false } }
            }
        }
        .sheet(item: $editingRecord) { RecordEditor(record: $0) }
        .sheet(isPresented: $showDetails) { details }
        .alert("Chat", isPresented: Binding(get: { error != nil || audio.error != nil }, set: { if !$0 { error = nil; audio.error = nil } })) {
            Button("OK") { error = nil; audio.error = nil }
        } message: { Text(error ?? audio.error ?? "") }
        .onChange(of: selectedPhoto) { _, selection in Task { await viewModel.loadPhoto(selection) } }
        .onDisappear { viewModel.stop() }
    }
    private var header: some View {
        HStack(spacing: 8) {
            Button { dismiss() } label: { Image(systemName: "chevron.left").font(.title3).frame(width: 40, height: 44) }.accessibilityLabel("Back")
            Image(systemName: "note.text").foregroundStyle(green).frame(width: 40, height: 40).background(DashboardPalette.mint.opacity(0.25), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text("Private notes").font(.headline .weight(.bold))
                Text("Your account • On this device").font(.caption2 .weight(.medium)).foregroundStyle(DashboardPalette.muted)
            }
            Spacer(minLength: 0)
            Button { showDetails = true } label: { Image(systemName: "ellipsis").frame(width: 40, height: 44) }.accessibilityLabel("Chat details")
        }.padding(.horizontal, 4).frame(height: 64).background(HomeMateStyle.background.opacity(0.95)).shadow(color: .black.opacity(0.04), radius: 4, y: 1)
    }
    private var contextBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "house.fill").foregroundStyle(green).frame(width: 32, height: 32).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(viewModel.profile.household).font(.caption .weight(.semibold))
                Text("Private attachments and reminders").font(.caption2).foregroundStyle(DashboardPalette.muted)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button { showRecords = true } label: { Image(systemName: "doc.badge.plus").frame(width: 32, height: 32).background(Color(uiColor: .secondarySystemGroupedBackground), in: Circle()) }.accessibilityLabel("Link bill or task")
        }.padding(8).background(DashboardPalette.surface, in: RoundedRectangle(cornerRadius: 12))
    }
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right").font(.largeTitle).foregroundStyle(green)
            Text("Your private notes").font(.headline .weight(.semibold))
            Text("Keep plans, bills and little reminders together. Messages stay on this device.").font(.footnote).multilineTextAlignment(.center).foregroundStyle(DashboardPalette.muted)
            Button("Preview the sample conversation") { viewModel.loadSample() }.font(.footnote .weight(.semibold))
        }.padding(24).frame(maxWidth: .infinity).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }
    private func messageRow(_ message: ChatMessage) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if message.isMine { Spacer(minLength: 36) }
            else { ProfileAvatar(data: nil, name: message.author, size: 32) }
            VStack(alignment: message.isMine ? .trailing : .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(message.isMine ? "You" : message.author).font(.caption2 .weight(.semibold))
                    Text(message.date.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(DashboardPalette.muted)
                    if message.isSample { Text("SAMPLE").font(.system(size: 9, weight: .semibold)).foregroundStyle(DashboardPalette.muted) }
                }.padding(.horizontal, 4)
                if focusedMessage == message.id {
                    HStack(spacing: 14) {
                        ForEach(["👍", "❤️", "😂", "🙏"], id: \.self) { reaction in Button(reaction) { viewModel.react(message, emoji: reaction); focusedMessage = nil }.font(.title2) }
                        Button { reply = message; focusedMessage = nil; composing = true } label: { Image(systemName: "arrowshape.turn.up.left") }.accessibilityLabel("Reply")
                        Menu {
                            Button("Copy text", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }
                            Button("Delete from this device", systemImage: "trash", role: .destructive) { viewModel.delete(message) }
                        } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Message actions")
                    }.padding(.horizontal, 12).padding(.vertical, 8).background(.regularMaterial, in: Capsule()).shadow(color: .black.opacity(0.1), radius: 10, y: 4)
                }
                VStack(alignment: .leading, spacing: 10) {
                    if let reply = message.replyPreview { Text(reply).font(.caption).lineLimit(3).padding(8).frame(maxWidth: .infinity, alignment: .leading).background(message.isMine ? .white.opacity(0.12) : green.opacity(0.06), in: RoundedRectangle(cornerRadius: 8)) }
                    if !message.text.isEmpty { Text(message.text).font(.body).lineSpacing(5).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                    if let data = message.photoData, let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 240).clipShape(RoundedRectangle(cornerRadius: 12)) }
                    if let filename = message.audioFile { Button { audio.play(filename, data: message.audioData) } label: { Label("Play voice note", systemImage: "play.circle.fill").font(.subheadline .weight(.semibold)) }.tint(message.isMine ? .white : green) }
                    if let id = message.recordID {
                        if let record = viewModel.personalRecords.first(where: { $0.id == id }) {
                            Button { editingRecord = record } label: { Label(record.title, systemImage: record.kind.icon).font(.caption .weight(.semibold)).padding(10).frame(maxWidth: .infinity, alignment: .leading).background(message.isMine ? .white.opacity(0.15) : green.opacity(0.07), in: RoundedRectangle(cornerRadius: 10)) }.buttonStyle(.plain)
                        } else { Text("Linked record was deleted").font(.caption) }
                    }
                }.padding(14).foregroundStyle(message.isMine ? .white : DashboardPalette.ink)
                    .background(message.isMine ? DashboardPalette.brandFill : Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                    .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
                    .onLongPressGesture { composing = false; withAnimation { focusedMessage = focusedMessage == message.id ? nil : message.id } }

                if let reaction = message.reaction { Button { viewModel.react(message, emoji: reaction) } label: { Text("\(reaction) 1").font(.caption).padding(.horizontal, 9).padding(.vertical, 5).background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule()).shadow(color: .black.opacity(0.06), radius: 3, y: 2) }.buttonStyle(.plain) }
            }.frame(maxWidth: contentWidth >= 700 ? 480 : 310, alignment: message.isMine ? .trailing : .leading)
            if !message.isMine { Spacer(minLength: 12) }
        }.frame(maxWidth: .infinity, alignment: message.isMine ? .trailing : .leading)
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let reply {
                HStack { Text("Reply to \(reply.author): \(reply.text)").font(.caption).lineLimit(1); Spacer(); Button { self.reply = nil } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Cancel reply") }
            }
            if photoData != nil || voiceFile != nil || linkedRecord != nil {
                HStack(spacing: 10) {
                    if photoData != nil { Button("Remove photo", systemImage: "photo.badge.minus") { photoData = nil } }
                    if voiceFile != nil { Button("Remove voice", systemImage: "waveform") { viewModel.discardVoice() } }
                    if let linkedRecord { Button(linkedRecord.title, systemImage: "xmark.circle") { self.linkedRecord = nil }.lineLimit(1) }
                }.font(.caption2)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(["I'll take care of it 👍", "Thanks everyone!", "What's needed at home?"], id: \.self) { suggestion in
                        Button(suggestion) { text = suggestion; composing = true }.font(.caption2 .weight(.medium)).padding(.horizontal, 12).padding(.vertical, 7).background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule()).overlay(Capsule().stroke(green.opacity(0.1)))
                    }
                }
            }
            HStack(spacing: 8) {
                Menu {
                    PhotosPicker(selection: $viewModel.selectedPhoto, matching: .images) { Label("Attach a photo or receipt", systemImage: "photo") }
                    Button("Link a bill or task", systemImage: "doc.badge.plus") { showRecords = true }
                } label: { Image(systemName: "plus").font(.title3).frame(width: 32, height: 40) }.accessibilityLabel("Add attachment")
                HStack(spacing: 6) {
                    TextField("Message \(viewModel.profile.household)…", text: $viewModel.text, axis: .vertical).lineLimit(1...4).font(.body).focused($composing)
                    if loadingPhoto { ProgressView() }
                    Button {
                        Task { await viewModel.toggleRecording() }
                    } label: { Image(systemName: audio.recording ? "stop.circle.fill" : "mic").foregroundStyle(audio.recording ? .red : DashboardPalette.muted).frame(width: 32, height: 36) }.disabled(audio.starting).accessibilityLabel(audio.recording ? "Finish recording" : "Record voice note")
                }.padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 3).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22)).overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.gray.opacity(0.12)))
                Button(action: viewModel.send) { Image(systemName: "arrow.up").font(.headline .weight(.semibold)).foregroundStyle(.white).frame(width: 40, height: 40).background(DashboardPalette.brandFill, in: Circle()).opacity(viewModel.ready ? 1 : 0.4) }.disabled(!viewModel.ready || loadingPhoto || audio.recording).accessibilityLabel("Save message on this device")
            }
            if audio.recording { Text("Recording • Tap stop to attach • Up to 60 seconds").font(.caption2).foregroundStyle(.red) }
        }.padding(.horizontal, 20).padding(.vertical, 10).frame(maxWidth: 900).frame(maxWidth: .infinity).background(.regularMaterial).shadow(color: .black.opacity(0.04), radius: 8, y: -4)
    }
    private var details: some View {
        NavigationStack {
            List {
                Section("Private to your account") { Text("These notes are not sent to your family. Use Family text chat inside a shared family to message real members.") }
                Section("Storage") { Text("These private notes, attachments and voice notes stay on this device in your account. For shared messages, open Family & sharing → your family → Family text chat.") }
                Section { Button("Remove sample messages", role: .destructive) { viewModel.removeSamples() }.disabled(!viewModel.personalMessages.contains { $0.isSample }) }
            }.navigationTitle("Chat details").navigationBarTitleDisplayMode(.inline).toolbar { Button("Done") { showDetails = false } }
        }
    }
    private func dayLabel(_ day: Date) -> String { (Calendar.current.isDateInToday(day) ? "TODAY • " : "") + day.formatted(.dateTime.month(.abbreviated).day()).uppercased() }





}
