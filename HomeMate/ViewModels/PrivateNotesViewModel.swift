import Foundation
import Combine
import PhotosUI
import SwiftUI

@MainActor
final class PrivateNotesViewModel: ScreenViewModel {
    @Published var text = ""
    @Published var reply: ChatMessage?
    @Published var selectedPhoto: PhotosPickerItem?
    @Published var photoData: Data?
    @Published var voiceFile: String?
    @Published var linkedRecord: HouseholdRecord?
    @Published var loadingPhoto = false
    @Published var error: String?

    var ready: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || photoData != nil || voiceFile != nil || linkedRecord != nil }
    var days: [Date] { Array(Set(store.messages.map { Calendar.current.startOfDay(for: $0.date) })).sorted() }
    func send() {
        guard isActive && ready && !audio.recording && !loadingPhoto else { return }
        var voiceData: Data?
        if let voiceFile {
            do { voiceData = try Data(contentsOf: ChatAudio.directory.appendingPathComponent(voiceFile)) }
            catch { self.error = error.localizedDescription; return }
        }
        let message = ChatMessage(author: store.profile.name, text: text.trimmingCharacters(in: .whitespacesAndNewlines), photoData: photoData, audioFile: voiceFile, audioData: voiceData, recordID: linkedRecord?.id, replyPreview: reply.map { "\($0.author): \($0.text.isEmpty ? "Attachment" : $0.text)" })
        guard store.replaceMessages(store.messages + [message]) else { error = store.error; return }
        text = ""; photoData = nil; selectedPhoto = nil; voiceFile = nil; linkedRecord = nil; reply = nil
    }
    func react(_ message: ChatMessage, emoji: String) {
        guard isActive else { return }
        guard let index = store.messages.firstIndex(where: { $0.id == message.id }) else { return }
        var updated = store.messages
        updated[index].reaction = updated[index].reaction == emoji ? nil : emoji
        if !store.replaceMessages(updated) { error = store.error }
    }
    func delete(_ message: ChatMessage) {
        guard isActive else { return }
        guard store.replaceMessages(store.messages.filter { $0.id != message.id }) else { error = store.error; return }
        if let filename = message.audioFile, filename == URL(fileURLWithPath: filename).lastPathComponent { try? FileManager.default.removeItem(at: ChatAudio.directory.appendingPathComponent(filename)) }
    }
    func discardVoice() {
        if let filename = voiceFile { try? FileManager.default.removeItem(at: ChatAudio.directory.appendingPathComponent(filename)) }
        voiceFile = nil
    }
    func loadSample() {
        guard isActive, store.messages.isEmpty else { return }
        let sample = [
            ChatMessage(author: "Kasun Chamara", text: "Hey everyone! Just a reminder that the electricity bill is due in 2 days. Let's check our shares before paying.", isMine: false, isSample: true, recordID: store.records.first(where: { $0.kind == .bill })?.id),
            ChatMessage(author: "Nimal Perera", text: "Thanks Kasun. I'm stopping by the supermarket around 4:30 PM. Does the pantry need Ceylon tea, eggs, or fresh milk?", isMine: false, isSample: true),
            ChatMessage(author: store.profile.name, text: "Yes please, let's add tea and fresh milk to the shopping list. I'll take care of the bill today!", isSample: true),
            ChatMessage(author: "Kasun Chamara", text: "Awesome! I also checked the living room AC filter this morning, all clean for Grandparents' visit on Sunday! 🌸", isMine: false, isSample: true, reaction: "❤️")
        ]
        if !store.replaceMessages(sample) { error = store.error }
    }

    let audio = ChatAudio()
    init(store: HouseholdStore, account: CloudAccount) {
        super.init(store: store, account: account); observe(audio)
    }
    func removeSamples() { guard isActive else { return }; store.replaceMessages(store.messages.filter { !$0.isSample }) }
    func stop() { audio.cancel(); discardVoice() }
    func toggleRecording() async { if audio.recording { voiceFile = audio.finish() } else { discardVoice(); await audio.start() } }
    func loadPhoto(_ selection: PhotosPickerItem?) async {
        loadingPhoto = true; defer { loadingPhoto = false }
        let scope = account.dataScope
        do {
            guard let data = try await selection?.loadTransferable(type: Data.self) else { error = "Could not read that photo."; return }
            let image = try ImageAttachmentService.noteThumbnail(data)
            if isCurrent(scope) { photoData = image }
        } catch { if isCurrent(scope) { self.error = error.localizedDescription } }
    }

}
