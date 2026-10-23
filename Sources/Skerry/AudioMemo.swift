import AVFoundation
import Foundation
import Observation
import Speech
import SwiftUI

/// SpeechTranscriber turns recorded audio into text strictly on device. If the device
/// cannot transcribe locally, it refuses rather than sending audio to a server.
enum SpeechTranscriber {
    /// Errors surfaced to the user.
    enum TranscribeError: Error, LocalizedError {
        /// The user declined speech recognition permission.
        case notAuthorized
        /// This device or language cannot transcribe on device.
        case onDeviceUnavailable
        /// Recognition ran but produced nothing.
        case empty

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "Speech recognition permission was declined."
            case .onDeviceUnavailable:
                return "On-device transcription is not available here, and Skerry never "
                    + "sends audio to a server."
            case .empty:
                return "No speech was recognized in that recording."
            }
        }
    }

    /// Asks for speech permission, returning whether it was granted.
    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    /// Transcribes an audio file on device.
    static func transcribe(url: URL) async throws -> String {
        guard await requestAuthorization() else { throw TranscribeError.notAuthorized }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable,
            recognizer.supportsOnDeviceRecognition
        else { throw TranscribeError.onDeviceUnavailable }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        let text: String = try await withCheckedThrowingContinuation { continuation in
            var finished = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let result, result.isFinal {
                    finished = true
                    continuation.resume(returning: result.bestTranscription.formattedString)
                } else if let error {
                    finished = true
                    continuation.resume(throwing: error)
                }
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TranscribeError.empty }
        return trimmed
    }
}

/// AudioMemoRecorder records a voice memo to a scratch file.
@MainActor
@Observable
final class AudioMemoRecorder {
    /// Whether recording is running.
    private(set) var isRecording = false
    /// Seconds recorded so far.
    private(set) var elapsed: TimeInterval = 0
    /// Underlying recorder.
    private var recorder: AVAudioRecorder?
    /// Ticks the elapsed display.
    private var timer: Task<Void, Never>?

    /// Starts recording; returns false when the microphone is unavailable.
    @discardableResult
    func start() -> Bool {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("memo-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        do {
            #if os(iOS)
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.record, mode: .default)
                try session.setActive(true)
            #endif
            let recorder = try AVAudioRecorder(url: scratch, settings: settings)
            guard recorder.record() else { return false }
            self.recorder = recorder
            isRecording = true
            elapsed = 0
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, self.isRecording else { break }
                    self.elapsed = self.recorder?.currentTime ?? self.elapsed + 1
                }
            }
            return true
        } catch {
            return false
        }
    }

    /// Stops recording and returns the audio file, nil when nothing was captured.
    func stop() -> URL? {
        timer?.cancel()
        timer = nil
        guard let recorder else { return nil }
        let url = recorder.url
        recorder.stop()
        self.recorder = nil
        isRecording = false
        #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false)
        #endif
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// RecordMemoView records a voice memo, transcribes it on device, and hands both back.
struct RecordMemoView: View {
    /// Receives the audio file and the transcript; the transcript is nil on failure.
    let onSave: (URL, String?, String?) -> Void
    /// Dismisses the sheet.
    @Environment(\.dismiss) private var dismiss
    /// Recorder state.
    @State private var recorder = AudioMemoRecorder()
    /// Whether transcription is running after stop.
    @State private var transcribing = false
    /// Message when recording could not start.
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 18) {
            Text(transcribing ? "Transcribing on device..." : "Audio Memo")
                .font(.headline)
            Image(systemName: recorder.isRecording ? "waveform" : "mic.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, isActive: recorder.isRecording || transcribing)
            Text(timeText)
                .font(.system(.title2, design: .monospaced))
                .foregroundStyle(.secondary)
            if let failure {
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 14) {
                Button("Cancel") {
                    _ = recorder.stop()
                    dismiss()
                }
                .disabled(transcribing)
                Button(recorder.isRecording ? "Stop and Save" : "Start Recording") {
                    if recorder.isRecording {
                        finish()
                    } else if !recorder.start() {
                        failure = "The microphone is unavailable. Check permissions in "
                            + "System Settings."
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(transcribing)
            }
        }
        .padding(28)
        #if os(macOS)
            .frame(minWidth: 360)
        #endif
        .interactiveDismissDisabled(recorder.isRecording || transcribing)
    }

    /// Elapsed time as minutes and seconds.
    private var timeText: String {
        let total = Int(recorder.elapsed)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Stops, transcribes, and hands the results back.
    private func finish() {
        guard let audio = recorder.stop() else {
            failure = "Nothing was recorded."
            return
        }
        transcribing = true
        Task {
            var transcript: String?
            var problem: String?
            do {
                transcript = try await SpeechTranscriber.transcribe(url: audio)
            } catch {
                problem = error.localizedDescription
            }
            onSave(audio, transcript, problem)
            dismiss()
        }
    }
}
