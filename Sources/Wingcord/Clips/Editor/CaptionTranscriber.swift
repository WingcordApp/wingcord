import AVFoundation
import CoreMedia
import Foundation
import Speech
import WingcordCore
import WingcordVoice

// MARK: - Captions from what was said (docs/CLIPS-PRESENCE.md, D14 / 5.4)
//
// On this Mac only: Apple's `SpeechAnalyzer` with a `SpeechTranscriber` asked
// for each word's time range. The track is written out mono first (a clip's
// voices are stems inside one file); the model for the language is fetched
// the first time, through the system's own asset store.

enum CaptionTranscriber {
    enum Failure: LocalizedError {
        case unsupportedLanguage
        case noSpeech

        var errorDescription: String? {
            switch self {
            case .unsupportedLanguage: "Captions aren't available in your language on this Mac."
            case .noSpeech: "No speech was found in that sound."
            }
        }
    }

    /// What is being done, for the inspector's line.
    enum Stage: Equatable {
        case preparing
        case downloading(Double)
        case listening
    }

    /// The words said on audio track `track` of `source`, each with its time
    /// in the source.
    static func transcribe(source: URL, track: Int, stage: @escaping @MainActor (Stage) -> Void) async throws -> [Caption.Word] {
        stage(.preparing)
        var locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
        if locale == nil { locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) }
        guard let locale else { throw Failure.unsupportedLanguage }
        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedTranscriptionWithAlternatives)

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            let progress = request.progress
            let watcher = Task { @MainActor in
                while !Task.isCancelled, !progress.isFinished {
                    stage(.downloading(progress.fractionCompleted))
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            defer { watcher.cancel() }
            try await request.downloadAndInstall()
        }

        let mono = FileManager.default.temporaryDirectory.appendingPathComponent("captions-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: mono) }
        try await VoiceCleanUp.extractMono(source: source, track: track, to: mono)
        let file = try AVAudioFile(forReading: mono)

        stage(.listening)
        // The results are read on a task of their own while the analyzer
        // works through the file; `finishAfterFile` ends both.
        let reading = Task {
            var words: [Caption.Word] = []
            for try await result in transcriber.results {
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let text = String(result.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    words.append(Caption.Word(text: text, start: range.start.seconds, end: range.end.seconds))
                }
            }
            return words
        }
        _ = try await SpeechAnalyzer(inputAudioFile: file, modules: [transcriber], finishAfterFile: true)
        let words = try await reading.value
        guard !words.isEmpty else { throw Failure.noSpeech }
        return words.sorted { $0.start < $1.start }
    }
}
