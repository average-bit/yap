import ArgumentParser
import NaturalLanguage
@preconcurrency import Noora
import Speech

// MARK: - Transcribe

@MainActor struct Transcribe: AsyncParsableCommand {
    @Option(
        name: .shortAndLong,
        help: "(default: current)",
        transform: Locale.init(identifier:)
    ) var locale: Locale = .init(identifier: Locale.current.identifier)

    @Flag(
        help: "Replaces certain words and phrases with a redacted form."
    ) var censor: Bool = false

    @Argument(
        help: "Path to an audio or video file to transcribe. Use 'mic' for live input.",
        transform: { (input: String) -> URL? in
            if input.lowercased() == "mic" {
                return nil // Represent live input with nil URL
            }
            return URL(fileURLWithPath: input)
        }
    ) var inputFile: URL?

    @Flag(
        help: "Output format for the transcription.",
    ) var outputFormat: OutputFormat = .txt

    @Option(
        name: .shortAndLong,
        help: "Path to save the transcription output. If not provided, output will be printed to stdout.",
        transform: URL.init(fileURLWithPath:)
    ) var outputFile: URL?

    mutating func run() async throws {
        let piped = isatty(STDOUT_FILENO) == 0
        struct DevNull: StandardPipelining { func write(content _: String) {} }
        let noora = if piped {
            Noora(standardPipelines: .init(output: DevNull()))
        } else {
            Noora()
        }

        let supported = await SpeechTranscriber.supportedLocales
        guard supported.map({ $0.identifier(.bcp47) }).contains(locale.identifier(.bcp47)) else {
            noora.error(.alert("Locale \"\(locale.identifier)\" is not supported. Supported locales:\n\(supported.map(\.identifier))"))
            throw Error.unsupportedLocale
        }

        for locale in await AssetInventory.allocatedLocales {
            await AssetInventory.deallocate(locale: locale)
        }
        try await AssetInventory.allocate(locale: locale)

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: censor ? [.etiquetteReplacements] : [],
            reportingOptions: [],
            attributeOptions: outputFormat.needsAudioTimeRange ? [.audioTimeRange] : []
        )
        let modules: [any SpeechModule] = [transcriber]
        let installed = await Set(SpeechTranscriber.installedLocales)
        if !installed.map({ $0.identifier(.bcp47) }).contains(locale.identifier(.bcp47)) {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                try await noora.progressBarStep(
                    message: "Downloading required assets…"
                ) { @Sendable progressCallback in
                    struct ProgressCallback: @unchecked Sendable {
                        let callback: (Double) -> Void
                    }
                    let progressCallback = ProgressCallback(callback: progressCallback)
                    Task {
                        while !request.progress.isFinished {
                            progressCallback.callback(request.progress.fractionCompleted)
                            try? await Task.sleep(for: .seconds(0.1))
                        }
                    }
                    try await request.downloadAndInstall()
                }
            }
        }

        let analyzer = SpeechAnalyzer(modules: modules)
        var transcript: AttributedString = ""
        let (inputSequence, inputBuilder) = AsyncStream.makeStream(of: AnalyzerInput.self)

        if let inputFile = inputFile { // Existing file input logic
            let audioFile = try AVAudioFile(forReading: inputFile)
            let audioFileDuration: TimeInterval = Double(audioFile.length) / audioFile.processingFormat.sampleRate
            try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)

            var w = winsize()
            let terminalColumns = if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &w) == 0 {
                max(Int(w.ws_col), 9)
            } else { 64 }

            try await noora.progressStep(
                message: "Transcribing audio using locale: \"\(locale.identifier)\"…",
                successMessage: "Audio transcribed using locale: \"\(locale.identifier)\"",
                errorMessage: "Failed to transcribe audio using locale: \"\(locale.identifier)\"",
                showSpinner: true
            ) { @Sendable progressHandler in
                for try await result in transcriber.results {
                    await MainActor.run {
                        transcript += result.text
                    }
                    let progress = max(min(result.resultsFinalizationTime.seconds / audioFileDuration, 1), 0)
                    var percent = progress.formatted(.percent.precision(.fractionLength(0)))
                    let oneHundredPercent = 1.0.formatted(.percent.precision(.fractionLength(0)))
                    percent = String(String(repeating: " ", count: max(oneHundredPercent.count - percent.count, 0))) + percent
                    let message = "[\(percent)] \(String(result.text.characters).trimmingCharacters(in: .whitespaces).prefix(terminalColumns - "⠋ [\(oneHundredPercent)] ".count))"
                    progressHandler(message)
                }
            }
        } else { // New live audio input logic
            print("Starting live transcription. Press Ctrl+C to stop.") // Changed from noora.standard
            let liveAudioRecorder = LiveAudioRecorder()
            // We need the audio format from the recorder to configure the analyzer
            // This requires a bit of a restructure or assumption. For now, let's assume a common format.
            // Or, we adapt SpeechAnalyzer initialization if possible after recorder setup.
            // For this iteration, we'll proceed with a placeholder for analyzer.start for live audio.
            // This part needs to be carefully integrated with SpeechAnalyzer's live input mechanism.

            // The Apple documentation suggests creating an AsyncStream for live input.
            // SpeechAnalyzer is initialized with this stream.
            // The LiveAudioRecorder will feed this stream.

            guard let audioFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
                noora.error(.alert("Could not determine a suitable audio format for live recording."))
                throw Error.liveAudioFormatUnavailable
            }

            // Re-initialize analyzer for live input
            let liveAnalyzer = SpeechAnalyzer(inputSequence: inputSequence, modules: modules)

            liveAudioRecorder.onAudioBuffer = { buffer in
                // Ensure the buffer is in the format expected by the analyzer
                // This might require format conversion if liveAudioRecorder.outputFormat differs from audioFormat
                guard let pcmBuffer = buffer.cloneToFormat(audioFormat) else {
                    // Log or handle format conversion error
                    print("Failed to convert buffer to analyzer's expected format.")
                    return
                }
                let input = AnalyzerInput(buffer: pcmBuffer)
                inputBuilder.yield(input)
            }

            try liveAudioRecorder.startRecording() // No output URL, streams directly

            // Handle results from live transcription
            Task {
                do {
                    for try await result in transcriber.results {
                        let bestTranscription = result.text
                        let plainTextBestTranscription = String(bestTranscription.characters)
                        // For live transcription, we might want to print incrementally
                        // or accumulate and print/save on stop.
                        // For now, let's accumulate and handle output after stop.
                        await MainActor.run {
                            transcript += bestTranscription
                            // Optionally, print live updates to console if not writing to a file later
                            if outputFile == nil && !piped {
                                print(plainTextBestTranscription, terminator: "\r")
                                fflush(stdout) // Ensure it prints immediately
                            }
                        }
                    }
                } catch {
                    // Handle errors from the results stream
                    noora.error(.alert("Error during live transcription: \(error)"))
                }
            }

            // Start analysis
            // The analyzeSequence call will suspend until the inputBuilder is finished.
            // We need a mechanism to stop recording and finish the inputBuilder (e.g., Ctrl+C).

            // Setup signal handler for Ctrl+C (SIGINT)
            // This is a simplified way; a more robust solution might be needed.
            let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            signal(SIGINT, SIG_IGN) // Ignore default handler to allow custom handling

            signalSource.setEventHandler {
                print("\nStopping live transcription...") // Changed from noora.standard
                liveAudioRecorder.stopRecording()
                inputBuilder.finish() // Finish the stream to end analysis
                signalSource.cancel() // Clean up signal handler
            }
            signalSource.resume()

            // This will block until inputBuilder.finish() is called
            _ = try await liveAnalyzer.analyzeSequence(inputSequence)
            try await liveAnalyzer.finalizeAndFinish()


            // After loop, if live printing was done, add a newline
            if outputFile == nil && !piped {
                print() // Move to next line after live updates
            }
        }

        // Output handling remains largely the same
        // Note: For live transcription, transcript is populated by the Task handling results.
        // Ensure this task completes or is handled before trying to use `transcript`.
        // The blocking nature of analyzeSequence should mean `transcript` is populated.

        var w = winsize()
        let terminalColumns = if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &w) == 0 {
            max(Int(w.ws_col), 9)
        } else { 64 }

        try await noora.progressStep(
            message: "Transcribing audio using locale: \"\(locale.identifier)\"…",
            successMessage: "Audio transcribed using locale: \"\(locale.identifier)\"",
            errorMessage: "Failed to transcribe audio using locale: \"\(locale.identifier)\"",
            showSpinner: true
        ) { @Sendable progressHandler in
            for try await result in transcriber.results {
                await MainActor.run {
                    transcript += result.text
                }
                let progress = max(min(result.resultsFinalizationTime.seconds / audioFileDuration, 1), 0)
                var percent = progress.formatted(.percent.precision(.fractionLength(0)))
                let oneHundredPercent = 1.0.formatted(.percent.precision(.fractionLength(0)))
                percent = String(String(repeating: " ", count: max(oneHundredPercent.count - percent.count, 0))) + percent
                let message = "[\(percent)] \(String(result.text.characters).trimmingCharacters(in: .whitespaces).prefix(terminalColumns - "⠋ [\(oneHundredPercent)] ".count))"
                progressHandler(message)
            }
        }

        if let outputFile {
            try outputFormat.text(for: transcript).write(
                to: outputFile,
                atomically: false,
                encoding: .utf8
            )
            noora.success(.alert("Transcription written to \(outputFile.path)"))
        }

        if piped || outputFile == nil {
            print(outputFormat.text(for: transcript))
        }
    }
}

// MARK: Transcribe.Error

extension Transcribe {
    enum Error: Swift.Error {
        case unsupportedLocale
        case liveAudioFormatUnavailable // New error case
    }
}

// Helper extension for AVAudioPCMBuffer cloning and format conversion
extension AVAudioPCMBuffer {
    func cloneToFormat(_ format: AVAudioFormat) -> AVAudioPCMBuffer? {
        // If the buffer is already in the target format, just return a clone
        if self.format == format {
            return self.clone()
        }

        // Otherwise, perform conversion
        let converter = AVAudioConverter(from: self.format, to: format)
        guard let converter = converter else {
            print("Failed to create AVAudioConverter.")
            return nil
        }

        // Calculate the output buffer capacity
        // The ratio of sample rates times the input frame capacity
        let outputFrameCapacity = AVAudioFrameCount(Double(self.frameLength) * (format.sampleRate / self.format.sampleRate))
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outputFrameCapacity) else {
            print("Failed to create output AVAudioPCMBuffer.")
            return nil
        }
        outputBuffer.frameLength = outputBuffer.frameCapacity // Important: Set frameLength to capacity for conversion

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return self
        }

        let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
        if status == .error || error != nil {
            print("Error during audio conversion: \(error?.localizedDescription ?? "Unknown error")")
            return nil
        }

        // After conversion, outputBuffer.frameLength is updated to the actual number of frames converted.
        return outputBuffer
    }

    // Helper to simply clone a buffer if format conversion is not needed or for other purposes
    func clone() -> AVAudioPCMBuffer? {
        guard let clone = AVAudioPCMBuffer(pcmFormat: self.format, frameCapacity: self.frameCapacity) else {
            return nil
        }
        clone.frameLength = self.frameLength
        if let src = self.floatChannelData, let dst = clone.floatChannelData {
            for channel in 0..<Int(self.format.channelCount) {
                dst[channel].initialize(from: src[channel], count: Int(self.frameLength))
            }
        } else if let src = self.int16ChannelData, let dst = clone.int16ChannelData {
             for channel in 0..<Int(self.format.channelCount) {
                dst[channel].initialize(from: src[channel], count: Int(self.frameLength))
            }
        } else if let src = self.int32ChannelData, let dst = clone.int32ChannelData {
            for channel in 0..<Int(self.format.channelCount) {
                dst[channel].initialize(from: src[channel], count: Int(self.frameLength))
            }
        } else {
            return nil // Unknown or unsupported buffer format
        }
        return clone
    }
}
