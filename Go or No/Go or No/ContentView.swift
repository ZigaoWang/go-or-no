//
//  ContentView.swift
//  Go or No
//
//  Created by Zigao Wang on 4/20/25.
//

import SwiftUI
import AVFoundation
import Vision
import VisionKit
import ARKit
import UIKit

struct ContentView: View {
    @StateObject private var viewModel = CameraViewModel()
    
    var body: some View {
        ZStack {
            // Camera feed
            ARCameraView(session: viewModel.arSession)
                .edgesIgnoringSafeArea(.all)
            
            VStack {
                Spacer()
                
                // Distance indicator
                VStack {
                    Text("Distance: \(String(format: "%.2f", viewModel.currentDistance)) m")
                        .font(.system(size: 42, weight: .bold))
                        .foregroundColor(.white)
                        .padding()
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(12)
                }
                .padding(.bottom, 10)
                
                // Analysis Result Display
                if !viewModel.analysisResultText.isEmpty {
                    Text(viewModel.analysisResultText)
                        .font(.body)
                        .foregroundColor(.white)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(12)
                        .padding(.horizontal)
                        .padding(.bottom, 30) // Spacing below description
                        .transition(.opacity.animation(.easeInOut))
                }
                
                // Target indicator in center
                Image(systemName: "target")
                    .font(.system(size: 50))
                    .foregroundColor(.red.opacity(0.7))
                    // Dynamic target size based on slider
                    .overlay(
                        Rectangle()
                            .stroke(Color.yellow.opacity(0.5), lineWidth: 2)
                            .frame(width: min(UIScreen.main.bounds.width, UIScreen.main.bounds.height) * viewModel.focusAreaSize,
                                   height: min(UIScreen.main.bounds.width, UIScreen.main.bounds.height) * viewModel.focusAreaSize)
                    )
                
                Spacer()

                // Analyze Button
                Button(action: { 
                    viewModel.analyzeCurrentImage()
                }) {
                    HStack {
                        Image(systemName: "eye.fill")
                        Text("Analyze")
                    }
                    .font(.headline)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(viewModel.isAnalyzing ? Color.gray : Color.purple)
                    .foregroundColor(.white)
                    .cornerRadius(15)
                }
                .disabled(viewModel.isAnalyzing)
                .padding(.horizontal)
                .padding(.bottom, 5) // Reduced padding slightly
                
                // Follow-up Button (conditionally shown)
                if viewModel.canAskFollowUp {
                    Button(action: { 
                        viewModel.handleFollowUpTap()
                    }) {
                        HStack {
                            Image(systemName: viewModel.isRecording ? "mic.fill" : "mic")
                            Text(viewModel.isRecording ? "Stop Recording" : "Ask Follow-up")
                        }
                        .font(.headline)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(viewModel.isRecording ? Color.red : Color.orange)
                        .foregroundColor(.white)
                        .cornerRadius(15)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 20)
                    .transition(.opacity.animation(.easeInOut))
                }
                
                HStack(spacing: 20) { // Group toggles together
                    Button(action: {
                        viewModel.toggleVibration()
                    }) {
                        VStack {
                            Image(systemName: viewModel.vibrationEnabled ? "iphone.radiowaves.left.and.right" : "iphone.slash")
                                .font(.system(size: 30))
                            Text(viewModel.vibrationEnabled ? "Vibration ON" : "Vibration OFF")
                                .font(.headline)
                        }
                        .padding()
                        .frame(width: 150, height: 100) // Adjusted width
                        .background(Color.white)
                        .foregroundColor(.blue)
                        .cornerRadius(20)
                    }
                    
                    Button(action: {
                        viewModel.toggleSound()
                    }) {
                        VStack {
                            Image(systemName: viewModel.soundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                                .font(.system(size: 30))
                            Text(viewModel.soundEnabled ? "Sound ON" : "Sound OFF")
                                .font(.headline)
                        }
                        .padding()
                        .frame(width: 150, height: 100) // Adjusted width
                        .background(Color.white)
                        .foregroundColor(.blue)
                        .cornerRadius(20)
                    }
                }
                .padding(.bottom, 50)
            }
        }
        .onAppear {
            viewModel.checkPermissionsAndStartSession()
        }
    }
}

struct ARCameraView: UIViewRepresentable {
    let session: ARSession
    
    func makeUIView(context: Context) -> UIView {
        let view = ARSCNView(frame: UIScreen.main.bounds)
        view.session = session
        view.automaticallyUpdatesLighting = true
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {}
}

class CameraViewModel: NSObject, ObservableObject, ARSessionDelegate {
    @Published var currentDistance: Double = 0.0
    @Published var vibrationEnabled: Bool = true
    @Published var soundEnabled: Bool = true // Controls distance speech
    @Published var focusAreaSize: CGFloat = 0.50
    @Published var isAnalyzing: Bool = false // State for analysis button
    @Published var analysisResultText: String = "" // State for description display
    @Published var canAskFollowUp: Bool = false // Flag to enable follow-up button
    @Published var isRecording: Bool = false // State for recording button

    let arSession = ARSession()
    private var timer: Timer? = nil
    private let feedbackGenerator = UIImpactFeedbackGenerator(style: .medium)
    // Speech Synthesis
    private let synthesizer = AVSpeechSynthesizer()
    private var lastSpokenDistance: Double = -1.0 
    private var lastSpeechTime: Date = Date.distantPast
    private let speechThrottleInterval: TimeInterval = 2.5 
    private let significantDistanceChange: Double = 0.1 
    
    // Store the latest frame for analysis
    private var latestFrame: ARFrame? = nil
    // Flag to prevent distance speech from interrupting analysis speech
    private var isSpeakingDescription: Bool = false 
    // Store last analyzed image data for follow-up
    private var lastAnalyzedImageData: Data? = nil 
    
    // Audio Recording Components
    private let audioEngineForRecord = AVAudioEngine()
    private var audioFileRecorder: AVAudioFile? = nil
    private var recordingTapInstalled = false
    
    private let backendBaseURL = "https://api.go-or-no.zigao.wang"
    private let networkTimeout: TimeInterval = 15.0 // Timeout in seconds
    
    override init() {
        super.init()
        synthesizer.delegate = self // Set delegate for speech finish detection
        // Configure audio session initially for playback
        configureAudioSession(forPlayback: true) 
        setupARSession()
    }

    // Configure the shared AVAudioSession
    private func configureAudioSession(forPlayback: Bool) {
        // Stop engines before changing category
        if audioEngineForRecord.isRunning { audioEngineForRecord.stop() }
        // if audioEngine.isRunning { audioEngine.stop() } // If using separate engine for playback

        do {
            let audioSession = AVAudioSession.sharedInstance()
            if forPlayback {
                // For speech synthesis
                try audioSession.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                print("Audio session configured for Playback.")
            } else {
                // For recording
                try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
                print("Audio session configured for Recording.")
            }
            try audioSession.setActive(true)
            
            // Restart necessary engines after setting active
            // if forPlayback && !audioEngine.isRunning { try audioEngine.start() } 
            // If using separate playback engine
            
        } catch {
            print("ERROR: Failed to configure AVAudioSession: \(error)")
            if !forPlayback { speak("Error setting up recorder.") }
        }
    }

    func setupARSession() {
        arSession.delegate = self
    }
    
    func checkPermissionsAndStartSession() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startARSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted {
                    DispatchQueue.main.async {
                        self?.startARSession()
                    }
                }
            }
        default:
            // Handle denied state if necessary
            print("Camera access denied.")
            break
        }
    }
    
    func startARSession() {
        let configuration = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics = .sceneDepth
        } else {
            print("Device does not support SceneDepth.")
            // Handle lack of depth support if necessary
        }

        arSession.run(configuration)

        // Start feedback timer
        startFeedbackTimer()
    }

    func toggleVibration() {
        vibrationEnabled.toggle()
    }

    func toggleSound() {
        soundEnabled.toggle()
        if !soundEnabled && synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
            isSpeakingDescription = false
        }
    }

    // Renamed function for clarity
    private func startFeedbackTimer() {
        feedbackGenerator.prepare() // Prepare haptics generator ONCE before timer starts

        timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in // 50Hz timer
            guard let self = self else { return }

            let distance = self.currentDistance
            if distance > 0 {
                let interval = self.calculateVibrationInterval(for: distance)
                let currentTime = Date().timeIntervalSince1970
                let isVeryClose = interval <= 0.015 // Max freq threshold
                let shouldTriggerRegular = Int(currentTime * 50) % max(Int(interval * 50), 1) == 0

                if isVeryClose || shouldTriggerRegular {
                    // Trigger Vibration if enabled
                    if self.vibrationEnabled {
                        self.feedbackGenerator.impactOccurred()
                    }

                    // --- Distance Speech Logic --- 
                    // Check if sound is enabled for distance, AND if the synthesizer is currently silent,
                    // AND if we are not intentionally speaking a long description.
                    if self.soundEnabled && !self.synthesizer.isSpeaking && !self.isSpeakingDescription { 
                        let now = Date()
                        let enoughTimePassed = now.timeIntervalSince(self.lastSpeechTime) > self.speechThrottleInterval
                        
                        // Speak distance only if enough time has passed since the last speech
                        if enoughTimePassed { 
                            let currentDistanceToSpeak = self.currentDistance 
                            if abs(currentDistanceToSpeak - self.lastSpokenDistance) > 0.05 || self.lastSpokenDistance < 0 {
                                self.speakDistance(currentDistanceToSpeak)
                                self.lastSpokenDistance = currentDistanceToSpeak
                                self.lastSpeechTime = now
                            }
                        } 
                    } 
                    // --- End Distance Speech Logic ---
                    
                    // Logic to stop synthesizer if sound toggle is disabled (moved outside the distance speech block)
                    else if !self.soundEnabled && self.synthesizer.isSpeaking {
                         self.synthesizer.stopSpeaking(at: .immediate)
                         // Ensure flag is reset if speech is cut off by disabling sound
                         self.isSpeakingDescription = false 
                    }
                }
            }
        }
    }

    private func calculateVibrationInterval(for distance: Double) -> Double {
        // Maximize sensitivity: Reach MAX frequency at 0.8m due to LiDAR inaccuracy
        let clampedDistance = min(max(distance, 0.1), 8.0)

        // Maximum vibration frequency at 0.8m and below
        if clampedDistance <= 0.8 {
            // Near-constant, maximum vibration frequency
            // Target ~66Hz
            return 0.015
        } else if clampedDistance <= 1.5 {
            // Rapidly decrease frequency from max at 0.8m to still high at 1.5m
            // 0.8m -> 0.015s (66 vibrations per second)
            // 1.5m -> 0.1s (10 vibrations per second)
            return 0.015 + (clampedDistance - 0.8) * (0.1 - 0.015) / (1.5 - 0.8)
        } else {
            // Gradually decrease frequency for farther distances
            // 1.5m -> 0.1s (10 vibrations per second)
            // 8.0m -> 1.0s (1 vibration per second)
            return 0.1 + (clampedDistance - 1.5) * (1.0 - 0.1) / (8.0 - 1.5)
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        self.latestFrame = frame // Keep track of the latest frame
        
        // Check if depth data is available
        guard let depthData = frame.sceneDepth else { return }
        let depthMap = depthData.depthMap // Get the pixel buffer
        
        // Get depth map dimensions
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard width > 0, height > 0 else { return }
        
        // Calculate focus rectangle in pixel coordinates
        let focusRect = calculateFocusRect(depthMapWidth: width, depthMapHeight: height)
        
        // Get minimum depth within the focus rectangle
        if let depth = getMinDepth(in: focusRect, from: depthMap) {
            DispatchQueue.main.async {
                // Slightly faster smoothing
                self.currentDistance = self.currentDistance * 0.6 + depth * 0.4
            }
        } // If depth is nil (no valid point found), distance is not updated
    }
    
    // Helper to calculate the focus rectangle based on focusAreaSize
    private func calculateFocusRect(depthMapWidth: Int, depthMapHeight: Int) -> CGRect {
        let rectWidth = CGFloat(depthMapWidth) * focusAreaSize
        let rectHeight = CGFloat(depthMapHeight) * focusAreaSize
        let rectX = (CGFloat(depthMapWidth) - rectWidth) / 2.0
        let rectY = (CGFloat(depthMapHeight) - rectHeight) / 2.0
        
        return CGRect(x: rectX, y: rectY, width: rectWidth, height: rectHeight)
    }
    
    // Updated function to get minimum depth in a CGRect
    private func getMinDepth(in rect: CGRect, from depthMap: CVPixelBuffer) -> Double? {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else {
            return nil
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)

        var minDepth: Double = Double.greatestFiniteMagnitude
        var validDepthFound = false

        // Define loop bounds, ensuring they are within the buffer dimensions
        let startX = max(0, Int(rect.minX))
        let endX = min(width, Int(rect.maxX))
        let startY = max(0, Int(rect.minY))
        let endY = min(height, Int(rect.maxY))

        // Ensure start is not greater than end
        guard startX < endX, startY < endY else {
             // If rect is outside bounds or invalid, return nil
             print("Warning: Focus rectangle outside bounds or invalid.")
             return nil // Don't fallback to center, just report no valid depth
         }

        // Iterate through the pixels in the rectangle (with a step to reduce computation)
        // Sample roughly 15x15 points within the rect for performance
        let step = max(1, Int(min(rect.width, rect.height) / 15.0))
        for y in stride(from: startY, to: endY, by: step) {
            for x in stride(from: startX, to: endX, by: step) {
                 if let depth = getDepthAtSinglePoint(x: x, y: y, depthMap: depthMap) {
                    minDepth = min(minDepth, depth)
                    validDepthFound = true
                }
            }
        }

        return validDepthFound ? minDepth : nil // Return nil if no valid depth found
    }

    // Helper function to get depth at a single point (remains the same)
    private func getDepthAtSinglePoint(x: Int, y: Int, depthMap: CVPixelBuffer) -> Double? {
        // Assumes base address is already locked and valid
        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)

        // Bounds check
        guard x >= 0, x < width, y >= 0, y < height else {
            return nil
        }

        let depthPointer = baseAddress.advanced(by: y * bytesPerRow + x * MemoryLayout<Float32>.size).assumingMemoryBound(to: Float32.self)
        let depthValue = Double(depthPointer.pointee)

        // Return nil if depth is invalid (0, negative, or infinity/NaN)
        guard depthValue > 0, depthValue.isFinite else {
            return nil
        }
        return depthValue
    }

    // --- Speech Function --- 
    // Modified to potentially speak descriptions too
    private func speak(_ text: String, isDescription: Bool = false) { // Added flag parameter
        
        // --- Interruption Logic --- 
        // ONLY interrupt if the NEW speech is a description.
        // Do NOT interrupt an ongoing description for a distance update.
        if isDescription { // Only descriptions can interrupt.
            if synthesizer.isSpeaking {
                print("Interrupting current speech for new description.")
                synthesizer.stopSpeaking(at: .immediate)
                // Explicitly reset flag here since we are interrupting
                isSpeakingDescription = false 
            }
            // Set flag because this new speech IS a description
            isSpeakingDescription = true
        } else { 
            // If this new speech is NOT a description, check if a description is ALREADY playing.
            if isSpeakingDescription {
                // A description is playing, ignore this non-description speech.
                print("Ignoring non-description speech while description is active: \(text)")
                return 
            } 
            // If no description is playing, it's okay to potentially interrupt 
            // whatever non-description might be playing (e.g. another distance).
            // (Though this case is less likely with current throttling)
             if synthesizer.isSpeaking {
                 synthesizer.stopSpeaking(at: .immediate)
             }
        }
        // --- End Interruption Logic ---
        
        print("Speaking: \(text)") // Log for debugging
        
        // Create and configure utterance
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95 // Keep slightly slower rate
        utterance.volume = 1.0 // Max volume
        
        // Speak the utterance
        synthesizer.speak(utterance)
    }
    
    // --- Image Analysis Function --- 
    func analyzeCurrentImage() {
        guard !isAnalyzing else { return } 
        guard let frame = latestFrame else {
            if !isSpeakingDescription { speak("Could not get camera view.") } 
            return
        }
        
        // Stop any current speech/recording before starting
        stopAudioActivities()
        
        isAnalyzing = true
        canAskFollowUp = false // Disable follow-up during analysis
        analysisResultText = "Analyzing..." 
        speak("Analyzing scene...") 
        
        // Get image from frame
        let pixelBuffer = frame.capturedImage
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            speak("Could not process image.")
            analysisResultText = "Error processing image."
            isAnalyzing = false
            return
        }
        let image = UIImage(cgImage: cgImage)
        
        // Resize image for faster upload (Reduced size further)
        let targetSize = CGSize(width: 512, height: 384) 
        guard let resizedImage = resizeImage(image: image, targetSize: targetSize), 
              let imageData = resizedImage.jpegData(compressionQuality: 0.7) else { // Use JPEG
            speak("Could not prepare image for analysis.")
            analysisResultText = "Error preparing image."
            isAnalyzing = false
            return
        }
        self.lastAnalyzedImageData = imageData // Store image data for follow-up
        
        // Convert to base64
        let base64Image = imageData.base64EncodedString()
        
        // --- Network Request --- 
        guard let url = URL(string: "\(backendBaseURL)/describe-image") else {
            speak("Invalid backend URL.")
            analysisResultText = "Configuration error."
            isAnalyzing = false
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = networkTimeout // Set request timeout
        
        let jsonBody: [String: String] = ["imageData": base64Image]
        
        do {
            request.httpBody = try JSONEncoder().encode(jsonBody)
        } catch {
            speak("Failed to encode request.")
            analysisResultText = "Error encoding request."
            isAnalyzing = false
            return
        }
        
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.isAnalyzing = false // Analysis finished (success or fail)
                
                if let error = error {
                    // Handle specific timeout error
                    if (error as NSError).code == NSURLErrorTimedOut {
                        print("Network Error: Request timed out.")
                        self?.speak("Analysis timed out. Please try again.")
                        self?.analysisResultText = "Analysis timed out."
                    } else {
                        print("Network Error: \(error.localizedDescription)")
                        self?.speak("Error analyzing scene. Check network connection.") // More specific error
                        self?.analysisResultText = "Network error."
                    }
                    return
                }
                
                guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                    print("Server Error: \(response.debugDescription)")
                    self?.speak("Error analyzing scene: Server issue.")
                    self?.analysisResultText = "Server error."
                    return
                }
                
                guard let data = data else {
                    self?.speak("No description received.")
                    self?.analysisResultText = "No description received."
                    return
                }
                
                // Decode JSON response (assuming { "description": "..." })
                struct DescriptionResponse: Decodable {
                    let description: String
                }
                
                do {
                    let decodedResponse = try JSONDecoder().decode(DescriptionResponse.self, from: data)
                    self?.analysisResultText = decodedResponse.description 
                    // Set canAskFollowUp only on successful description
                    self?.canAskFollowUp = true 
                    self?.speak(decodedResponse.description, isDescription: true) 
                } catch {
                    print("JSON Decoding Error: \(error)")
                    self?.speak("Could not understand analysis response.")
                    self?.analysisResultText = "Error decoding response."
                    self?.canAskFollowUp = false // Can't follow up on error
                }
            }
        }
        task.resume()
    }
    
    // --- Helper Functions --- 
    
    // Simple image resizing helper
    private func resizeImage(image: UIImage, targetSize: CGSize) -> UIImage? {
        let size = image.size
        
        let widthRatio  = targetSize.width  / size.width
        let heightRatio = targetSize.height / size.height
        
        var newSize: CGSize
        if(widthRatio > heightRatio) {
            newSize = CGSize(width: size.width * heightRatio, height: size.height * heightRatio)
        } else {
            newSize = CGSize(width: size.width * widthRatio, height: size.height * widthRatio)
        }
        
        let rect = CGRect(x: 0, y: 0, width: newSize.width, height: newSize.height)
        
        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        image.draw(in: rect)
        let newImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        
        return newImage
    }
    
    // Renamed speakDistance to use generic speak function
    private func speakDistance(_ distance: Double) {
        let distanceString = String(format: "%.1f", distance)
        let speechString = "\(distanceString) meters."
        // Make sure to call speak with isDescription: false
        speak(speechString, isDescription: false) 
    }

    // --- Follow-up and Recording Logic --- 

    func handleFollowUpTap() {
        if isRecording {
            stopRecordingAndAnalyze()
        } else {
            startRecording()
        }
    }

    private func requestMicrophonePermission(completion: @escaping (Bool) -> Void) {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            completion(true)
        case .denied:
            speak("Microphone access denied. Please enable it in Settings.")
            completion(false)
        case .undetermined:
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async {
                    if !granted {
                        self.speak("Microphone access denied.")
                    }
                    completion(granted)
                }
            }
        @unknown default:
            completion(false)
        }
    }

    private func startRecording() {
        requestMicrophonePermission { [weak self] granted in
            guard let self = self, granted else { 
                self?.isRecording = false // Ensure UI state is correct
                return 
            }
            
            // Stop any ongoing speech
            if self.synthesizer.isSpeaking { self.synthesizer.stopSpeaking(at: .immediate) }
            self.isSpeakingDescription = false // Reset flag

            // Configure session for recording
            self.configureAudioSession(forPlayback: false)
            
            let inputNode = self.audioEngineForRecord.inputNode
            // Use input node's format initially, but we'll override for WAV
            // let recordingFormat = inputNode.outputFormat(forBus: 0)
            
            // --- Define WAV file format settings --- 
            var wavSettings = inputNode.outputFormat(forBus: 0).settings
            // Ensure Linear PCM format
            wavSettings[AVFormatIDKey] = kAudioFormatLinearPCM
            // Optional: Specify sample rate, bit depth if needed (often defaults work)
            // wavSettings[AVSampleRateKey] = 44100.0
            // wavSettings[AVNumberOfChannelsKey] = 1
            // wavSettings[AVLinearPCMBitDepthKey] = 16 
            // wavSettings[AVLinearPCMIsBigEndianKey] = false
            // wavSettings[AVLinearPCMIsFloatKey] = false
            // --- End WAV Settings ---
            
            // Define file path (using temporary directory with .wav extension)
            let tempDir = FileManager.default.temporaryDirectory
            let audioFilename = tempDir.appendingPathComponent("followup_recording.wav") // Changed extension
            // Delete previous file if it exists
            if FileManager.default.fileExists(atPath: audioFilename.path) {
                try? FileManager.default.removeItem(at: audioFilename)
            }

            do {
                // Create the audio file with WAV settings
                self.audioFileRecorder = try AVAudioFile(forWriting: audioFilename, settings: wavSettings) // Use wavSettings
                
                // Install tap only if not already installed
                if !self.recordingTapInstalled {
                    // Get format matching the file settings for the tap
                    guard let tapFormat = AVAudioFormat(settings: wavSettings) else {
                        throw NSError(domain: "AudioFormatError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create AVAudioFormat for tap"]) 
                    }
                    inputNode.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { [weak self] (buffer, when) in
                        do {
                            // Ensure the buffer format matches the file format before writing
                             guard buffer.format.settings[AVFormatIDKey] as? UInt32 == kAudioFormatLinearPCM else {
                                 // Attempt conversion if formats don't match (might be lossy/fail)
                                 print("Warning: Buffer format does not match WAV file format. Attempting conversion...")
                                 if let converter = AVAudioConverter(from: buffer.format, to: tapFormat), 
                                    let convertedBuffer = AVAudioPCMBuffer(pcmFormat: tapFormat, frameCapacity: buffer.frameCapacity) {
                                     var error: NSError? = nil
                                     converter.convert(to: convertedBuffer, error: &error, withInputFrom: { _, outStatus in
                                         outStatus.pointee = .haveData
                                         return buffer
                                     })
                                     if error == nil {
                                         try self?.audioFileRecorder?.write(from: convertedBuffer)
                                     } else {
                                         print("Audio conversion error: \(error?.localizedDescription ?? "Unknown")")
                                     }
                                 } else {
                                     print("Error: Could not create converter or converted buffer.")
                                 }
                                 return // Don't write original buffer if formats mismatch
                             }
                            // Formats match, write directly
                            try self?.audioFileRecorder?.write(from: buffer)
                        } catch {
                            print("Error writing audio buffer: \(error)")
                        }
                    }
                    self.recordingTapInstalled = true
                }
                
                // Prepare and start the engine
                self.audioEngineForRecord.prepare()
                try self.audioEngineForRecord.start()
                
                DispatchQueue.main.async {
                    self.isRecording = true
                    self.speak("Recording started.")
                }

            } catch {
                print("Error starting recording: \(error)")
                 DispatchQueue.main.async {
                     self.isRecording = false
                     self.speak("Could not start recording.")
                     // Revert audio session if recording fails
                     self.configureAudioSession(forPlayback: true)
                 }
            }
        }
    }

    private func stopRecordingAndAnalyze() {
        guard isRecording else { return }
        
        isRecording = false // Update UI immediately
        
        // Stop audio engine and remove tap
        audioEngineForRecord.stop()
        if recordingTapInstalled {
             audioEngineForRecord.inputNode.removeTap(onBus: 0)
             recordingTapInstalled = false
        }
       
        guard let recordingURL = audioFileRecorder?.url else {
            print("Error: Recording URL is nil.")
            speak("Failed to get recording.")
            configureAudioSession(forPlayback: true) // Revert session
            return
        }
        
        // Invalidate file reference
        audioFileRecorder = nil 
        
        // Reconfigure audio session for playback (for potential speech synthesis)
        configureAudioSession(forPlayback: true)
        speak("Recording stopped. Analyzing follow-up...")

        // --- Prepare and Send Follow-up Request --- 
        guard let lastImageData = lastAnalyzedImageData else {
            speak("Could not get previous image context for follow-up.")
            analysisResultText = "Missing image context."
            return
        }
        
        guard let audioData = try? Data(contentsOf: recordingURL) else {
             speak("Could not read recording data.")
             analysisResultText = "Error reading recording."
             return
        }
        let base64Audio = audioData.base64EncodedString()
        let base64Image = lastImageData.base64EncodedString()
        
        // Send request (similar structure to analyzeCurrentImage)
        sendFollowUpRequest(imageData: base64Image, audioData: base64Audio)
        
        // Optionally delete the temp file now, or rely on OS cleanup
        // try? FileManager.default.removeItem(at: recordingURL)
    }

    private func sendFollowUpRequest(imageData: String, audioData: String) {
        isAnalyzing = true // Use the same flag to disable buttons
        analysisResultText = "Analyzing follow-up..."
        
        guard let url = URL(string: "\(backendBaseURL)/follow-up-analysis") else {
            speak("Invalid follow-up URL.")
            analysisResultText = "Configuration error."
            isAnalyzing = false
            canAskFollowUp = true // Re-enable follow-up button on config error
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = networkTimeout * 2 // Allow longer for transcription+analysis
        
        let jsonBody: [String: String] = ["imageData": imageData, "audioData": audioData]
        
        do {
            request.httpBody = try JSONEncoder().encode(jsonBody)
        } catch {
            speak("Failed to encode follow-up request.")
            analysisResultText = "Error encoding request."
            isAnalyzing = false
            canAskFollowUp = true // Re-enable follow-up button
            return
        }
        
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.isAnalyzing = false
                self?.canAskFollowUp = true // Re-enable follow-up button after completion
                
                if let error = error {
                     if (error as NSError).code == NSURLErrorTimedOut {
                         self?.speak("Follow-up analysis timed out.")
                         self?.analysisResultText = "Follow-up timed out."
                     } else {
                         self?.speak("Error with follow-up analysis.")
                         self?.analysisResultText = "Network error during follow-up."
                     }
                     return
                 }
                 
                 guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                     self?.speak("Server error during follow-up.")
                     self?.analysisResultText = "Server error during follow-up."
                     return
                 }
                 
                 guard let data = data else {
                     self?.speak("No answer received for follow-up.")
                     self?.analysisResultText = "No answer received."
                     return
                 }
                 
                 // Decode JSON response (assuming { "answer": "..." })
                 struct AnswerResponse: Decodable {
                     let answer: String
                 }
                 
                 do {
                     let decodedResponse = try JSONDecoder().decode(AnswerResponse.self, from: data)
                     // Prepend question context? Maybe not needed if answer is direct.
                     let resultText = "Follow-up: \n" + decodedResponse.answer
                     self?.analysisResultText = resultText
                     self?.speak(decodedResponse.answer, isDescription: true) // Speak the follow-up answer
                 } catch {
                     self?.speak("Could not understand follow-up answer.")
                     self?.analysisResultText = "Error decoding answer."
                 }
            }
        }
        task.resume()
    }
    
    // Helper to stop all audio activities
    private func stopAudioActivities() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        if audioEngineForRecord.isRunning { 
            audioEngineForRecord.stop()
            if recordingTapInstalled { 
                 audioEngineForRecord.inputNode.removeTap(onBus: 0)
                 recordingTapInstalled = false
            }
        }
        isSpeakingDescription = false
        isRecording = false
        // Ensure session is back to playback after stopping everything
        configureAudioSession(forPlayback: true)
    }
}

// Add Speech Synthesizer Delegate extension
extension CameraViewModel: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        // Reset the flag when speech finishes
        DispatchQueue.main.async {
             print("Speech finished, resetting flag.")
            self.isSpeakingDescription = false
        }
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        // Also reset the flag if speech is cancelled
         DispatchQueue.main.async {
             print("Speech cancelled, resetting flag.")
             self.isSpeakingDescription = false
         }
    }
}

#Preview {
    ContentView()
}
