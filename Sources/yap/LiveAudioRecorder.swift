import AVFoundation

class LiveAudioRecorder {
    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var audioFile: AVAudioFile?
    private(set) var outputFormat: AVAudioFormat? // Made outputFormat publicly readable but privately settable

    var isRecording: Bool {
        return audioEngine?.isRunning ?? false
    }

    // Adding a callback for when audio data is available
    var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?

    init() {
        // setupAudioSession() removed as AVAudioSession is not used this way on macOS
    }

    func startRecording(outputURL: URL? = nil) throws {
        audioEngine = AVAudioEngine()
        guard let audioEngine = audioEngine else {
            throw LiveAudioError.audioEngineInitializationFailed
        }

        inputNode = audioEngine.inputNode
        guard let inputNode = inputNode else {
            throw LiveAudioError.inputNodeUnavailable
        }

        let inputBusFormat = inputNode.outputFormat(forBus: 0)
        // Ensure outputFormat is set, defaulting to input format if not specified for file writing
        self.outputFormat = inputBusFormat

        if let outputURL = outputURL {
            do {
                audioFile = try AVAudioFile(forWriting: outputURL, settings: inputBusFormat.settings)
            } catch {
                print("Failed to create audio file: \(error)")
                throw LiveAudioError.audioFileCreationFailure(error)
            }
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputBusFormat) { [weak self] (buffer, when) in
            guard let self = self else { return }

            // Call the callback if it's set
            self.onAudioBuffer?(buffer)

            // Write to file if audioFile is available
            if let audioFile = self.audioFile {
                do {
                    try audioFile.write(from: buffer)
                } catch {
                    // This error should be propagated or handled, e.g., by stopping recording
                    print("Error writing audio buffer to file: \(error)")
                }
            }
        }

        do {
            audioEngine.prepare() // Prepare the engine before starting (does not throw)
            try audioEngine.start()
        } catch {
            print("Could not start audioEngine: \(error)")
            // Clean up resources
            self.audioEngine = nil
            self.inputNode = nil
            self.audioFile = nil
            throw LiveAudioError.audioEngineStartFailed(error)
        }
    }

    func stopRecording() {
        audioEngine?.stop()
        inputNode?.removeTap(onBus: 0)

        // It's important to release the engine and nodes
        audioEngine = nil
        inputNode = nil
        audioFile = nil // This will close the file

        // Consider deactivating the audio session if it's no longer needed
        // This depends on whether other parts of the app might need it active
        // do {
        //     try AVAudioSession.sharedInstance().setActive(false)
        // } catch {
        //     print("Failed to deactivate audio session: \(error)")
        // }
    }
}

// Define custom errors for more specific error handling
enum LiveAudioError: Error {
    case audioEngineInitializationFailed
    case inputNodeUnavailable
    case audioFileCreationFailure(Error)
    case audioEngineStartFailed(Error)
}
