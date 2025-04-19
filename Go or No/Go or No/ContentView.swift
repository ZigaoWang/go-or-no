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

struct ContentView: View {
    @StateObject private var viewModel = CameraViewModel()
    @State private var autoSpeakEnabled = true
    
    var body: some View {
        ZStack {
            // Camera feed
            CameraView(session: viewModel.session)
                .edgesIgnoringSafeArea(.all)
            
            VStack {
                // Settings toggle at the top
                HStack {
                    Toggle("Auto-Speak", isOn: $autoSpeakEnabled)
                        .padding()
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(12)
                        .foregroundColor(.white)
                        .accessibilityHint("Toggle automatic voice announcements")
                        .onChange(of: autoSpeakEnabled) { newValue in
                            viewModel.setAutoSpeak(enabled: newValue)
                        }
                    
                    Spacer()
                }
                .padding(.top, 60)
                .padding(.horizontal)
                
                Spacer()
                
                // Display detected objects and decision
                VStack(spacing: 20) {
                    HStack(spacing: 30) {
                        if viewModel.showLeftDirection {
                            Image(systemName: "arrow.left")
                                .font(.system(size: 60))
                                .foregroundColor(.yellow)
                                .accessibilityLabel("Turn left")
                        }
                        
                        Text(viewModel.decision)
                            .font(.system(size: 72, weight: .bold))
                            .foregroundColor(viewModel.decision == "GO" ? .green : .red)
                            .accessibilityLabel("\(viewModel.decision)")
                        
                        if viewModel.showRightDirection {
                            Image(systemName: "arrow.right")
                                .font(.system(size: 60))
                                .foregroundColor(.yellow)
                                .accessibilityLabel("Turn right")
                        }
                    }
                    .padding()
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(12)
                    
                    Text(viewModel.detectionDescription)
                        .font(.title2)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.white)
                        .padding()
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(12)
                        .accessibilityLabel(viewModel.detectionDescription)
                }
                .padding(.bottom, 50)
                .accessibilityElement(children: .combine)
                
                // Large buttons for manual control
                HStack(spacing: 40) {
                    Button(action: {
                        viewModel.speakFeedback()
                    }) {
                        VStack {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.system(size: 30))
                            Text("Speak")
                                .font(.headline)
                        }
                        .padding()
                        .frame(width: 100, height: 100)
                        .background(Color.white)
                        .foregroundColor(.blue)
                        .clipShape(Circle())
                    }
                    .accessibilityLabel("Speak current status")
                    
                    Button(action: {
                        viewModel.toggleWalkingMode()
                    }) {
                        VStack {
                            Image(systemName: viewModel.isWalkingMode ? "figure.walk.circle.fill" : "figure.walk.circle")
                                .font(.system(size: 30))
                            Text(viewModel.isWalkingMode ? "Walking" : "Standing")
                                .font(.headline)
                        }
                        .padding()
                        .frame(width: 100, height: 100)
                        .background(Color.white)
                        .foregroundColor(.blue)
                        .clipShape(Circle())
                    }
                    .accessibilityLabel(viewModel.isWalkingMode ? "Switch to standing mode" : "Switch to walking mode")
                }
                .padding(.bottom, 50)
            }
        }
        .onAppear {
            viewModel.checkPermissionsAndStartSession()
            viewModel.setAutoSpeak(enabled: autoSpeakEnabled)
        }
    }
}

struct CameraView: UIViewRepresentable {
    let session: AVCaptureSession
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: UIScreen.main.bounds)
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.frame = view.frame
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {}
}

class CameraViewModel: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var decision: String = "..."
    @Published var detectionDescription: String = "Analyzing..."
    @Published var showLeftDirection: Bool = false
    @Published var showRightDirection: Bool = false
    @Published var isWalkingMode: Bool = false
    
    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let synthesizer = AVSpeechSynthesizer()
    
    private var lastSpokenTime: Date = Date()
    private var lastProcessTime: Date = Date()
    private var autoSpeakEnabled: Bool = true
    private var lastDecision: String = ""
    
    override init() {
        super.init()
        setupSession()
    }
    
    func checkPermissionsAndStartSession() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted {
                    DispatchQueue.main.async {
                        self?.startSession()
                    }
                }
            }
        default:
            break
        }
    }
    
    func setAutoSpeak(enabled: Bool) {
        autoSpeakEnabled = enabled
    }
    
    func toggleWalkingMode() {
        isWalkingMode.toggle()
        
        // Announce mode change
        let utterance = AVSpeechUtterance(string: isWalkingMode ? "Walking mode activated" : "Standing mode activated")
        utterance.rate = 0.5
        utterance.volume = 1.0
        synthesizer.speak(utterance)
    }
    
    private func setupSession() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { return }
        
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
            }
            
            videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "videoQueue"))
            if session.canAddOutput(videoOutput) {
                session.addOutput(videoOutput)
            }
            
            // Configure for high frame rate if possible
            if device.activeFormat.videoSupportedFrameRateRanges.first?.maxFrameRate ?? 0 > 30 {
                try device.lockForConfiguration()
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 60)
                device.unlockForConfiguration()
            }
        } catch {
            print("Error setting up camera: \(error)")
        }
    }
    
    func startSession() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }
    }
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        // Process every 0.3 seconds for better performance
        let now = Date()
        if now.timeIntervalSince(lastProcessTime) < 0.3 {
            return
        }
        lastProcessTime = now
        
        // Perform multiple vision tasks in parallel for better scene understanding
        performVisionAnalysis(on: pixelBuffer)
    }
    
    private func performVisionAnalysis(on pixelBuffer: CVPixelBuffer) {
        // Create a handler for the current frame
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        
        // Create various vision requests
        let objectDetectionRequest = VNDetectRectanglesRequest(completionHandler: handleObjectDetection)
        let humanDetectionRequest = VNDetectHumanRectanglesRequest(completionHandler: handleHumanDetection)
        let textDetectionRequest = VNRecognizeTextRequest(completionHandler: handleTextDetection)
        
        // Set up the requests
        objectDetectionRequest.minimumAspectRatio = 0.3
        objectDetectionRequest.maximumAspectRatio = 0.9
        objectDetectionRequest.minimumSize = 0.1
        objectDetectionRequest.maximumObservations = 10
        
        textDetectionRequest.recognitionLevel = .accurate
        textDetectionRequest.usesLanguageCorrection = true
        
        // Perform the requests in parallel
        try? handler.perform([objectDetectionRequest, humanDetectionRequest, textDetectionRequest])
    }
    
    private var detectedObstacles = false
    private var detectedHumans = false
    private var detectedText: [String] = []
    private var obstaclePositions: [CGPoint] = []
    
    private func handleObjectDetection(request: VNRequest, error: Error?) {
        guard let results = request.results as? [VNRectangleObservation] else { return }
        
        // Store obstacle positions to determine direction
        obstaclePositions = results.map { CGPoint(x: $0.boundingBox.midX, y: $0.boundingBox.midY) }
        
        // Consider objects in the center or taking up significant space as obstacles
        let significantObstacles = results.filter { observation in
            let centerX = observation.boundingBox.midX
            let centerY = observation.boundingBox.midY
            let area = observation.boundingBox.width * observation.boundingBox.height
            
            // Object is in center path or large
            return (centerX > 0.3 && centerX < 0.7 && centerY > 0.3) || area > 0.15
        }
        
        detectedObstacles = !significantObstacles.isEmpty
        updateDecision()
    }
    
    private func handleHumanDetection(request: VNRequest, error: Error?) {
        guard let results = request.results as? [VNHumanObservation] else { return }
        
        detectedHumans = !results.isEmpty
        updateDecision()
    }
    
    private func handleTextDetection(request: VNRequest, error: Error?) {
        guard let results = request.results as? [VNRecognizedTextObservation] else { return }
        
        let recognizedStrings = results.compactMap { observation -> String? in
            return observation.topCandidates(1).first?.string
        }
        
        if !recognizedStrings.isEmpty {
            detectedText = recognizedStrings
        }
        
        updateDecision()
    }
    
    private func updateDecision() {
        // Combine all detection results to make a decision
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Determine direction guidance based on obstacle positions
            self.showLeftDirection = false
            self.showRightDirection = false
            
            let oldDecision = self.decision
            
            if self.detectedHumans {
                self.decision = "NO"
                self.detectionDescription = "Caution: Person ahead"
            } else if self.detectedObstacles {
                self.decision = "NO"
                
                // Calculate which direction has fewer obstacles for guidance
                if !self.obstaclePositions.isEmpty {
                    let leftSideObstacles = self.obstaclePositions.filter { $0.x < 0.5 }.count
                    let rightSideObstacles = self.obstaclePositions.filter { $0.x >= 0.5 }.count
                    
                    if leftSideObstacles > rightSideObstacles {
                        self.showRightDirection = true
                        self.detectionDescription = "Obstacle ahead. Try right."
                    } else if rightSideObstacles > leftSideObstacles {
                        self.showLeftDirection = true
                        self.detectionDescription = "Obstacle ahead. Try left."
                    } else {
                        self.detectionDescription = "Obstacle in path"
                    }
                } else {
                    self.detectionDescription = "Obstacle in path"
                }
            } else {
                self.decision = "GO"
                
                if !self.detectedText.isEmpty && self.isWalkingMode {
                    // Just mention the first text item if present during walking
                    let firstText = self.detectedText.first ?? ""
                    if firstText.count < 15 { // Only mention short text
                        self.detectionDescription = "Path clear. \(firstText) ahead."
                    } else {
                        self.detectionDescription = "Path clear."
                    }
                } else {
                    self.detectionDescription = "Path clear"
                }
            }
            
            // Speak automatically if enabled and decision changed
            let now = Date()
            if self.autoSpeakEnabled && 
               (self.decision != oldDecision || now.timeIntervalSince(self.lastSpokenTime) > 5.0) && 
               oldDecision != "..." { // Don't speak the initial state
                self.speakFeedback()
            }
        }
    }
    
    func speakFeedback() {
        var speechText = "\(decision). \(detectionDescription)"
        
        // Add direction to speech if needed
        if showLeftDirection {
            speechText += " Turn left."
        } else if showRightDirection {
            speechText += " Turn right."
        }
        
        let utterance = AVSpeechUtterance(string: speechText)
        utterance.rate = 0.5
        utterance.volume = 1.0
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        
        synthesizer.speak(utterance)
        lastSpokenTime = Date()
    }
}

#Preview {
    ContentView()
}
