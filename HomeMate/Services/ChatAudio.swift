import Foundation
import Combine
import AVFoundation
@MainActor
final class ChatAudio: ObservableObject {
    @Published var recording = false
    @Published var starting = false
    @Published var error: String?
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var recordingURL: URL?
    private var requestID = UUID()
    static var directory: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    func start() async {
        guard !starting && !recording else { return }
        starting = true
        let currentRequest = UUID()
        requestID = currentRequest
        defer { starting = false }
        let allowed = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard requestID == currentRequest else { return }
        guard allowed else { error = "Allow microphone access in iOS Settings to record a voice note."; return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
            recorder = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue])
            guard recorder?.record(forDuration: 60) == true else { throw URLError(.cannotCreateFile) }
            recordingURL = url; recording = true
        } catch { self.error = error.localizedDescription }
    }
    func finish() -> String? {
        recorder?.stop(); recording = false
        defer { recorder = nil; recordingURL = nil; try? AVAudioSession.sharedInstance().setActive(false) }
        guard let url = recordingURL else { return nil }
        do {
            try FileManager.default.moveItem(at: url, to: Self.directory.appendingPathComponent(url.lastPathComponent))
            return url.lastPathComponent
        } catch { self.error = error.localizedDescription; return nil }
    }
    func cancel() {
        requestID = UUID()
        recorder?.stop(); recording = false
        if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
        recorder = nil; recordingURL = nil
        player?.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
    }
    func play(_ filename: String, data: Data? = nil) {
        guard filename == URL(fileURLWithPath: filename).lastPathComponent else { error = "Invalid voice-note attachment."; return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            if let data { player = try AVAudioPlayer(data: data) }
            else { player = try AVAudioPlayer(contentsOf: Self.directory.appendingPathComponent(filename)) }
            player?.play()
        } catch { self.error = error.localizedDescription }
    }
}
