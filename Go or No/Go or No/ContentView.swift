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
    
    var body: some View {
        ZStack {
            // Camera feed
            CameraView(session: viewModel.session)
                .edgesIgnoringSafeArea(.all)
            
        VStack {
                Spacer()
                
                // Display detected objects and decision
                VStack(spacing: 20) {
                    Text(viewModel.decision)
                        .font(.system(size: 72, weight: .bold))
                        .foregroundColor(viewModel.decision == "GO" ? .green : .red)
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
                }
                .padding(.bottom, 50)
                
                Button(action: {
                    viewModel.speakFeedback()
                }) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 30))
                        .padding()
                        .background(Color.white)
                        .foregroundColor(.blue)
                        .clipShape(Circle())
                }
                .padding(.bottom, 30)
            }
        }
        .onAppear {
            viewModel.checkPermissionsAndStartSession()
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
    
    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let synthesizer = AVSpeechSynthesizer()
    
    private var lastSpokenTime: Date = Date()
    private var lastProcessTime: Date = Date()
    
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
    
    private func handleObjectDetection(request: VNRequest, error: Error?) {
        guard let results = request.results as? [VNRectangleObservation] else { return }
        
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
            
            if self.detectedHumans {
                self.decision = "NO"
                self.detectionDescription = "Caution: Person detected"
            } else if self.detectedObstacles {
                self.decision = "NO"
                self.detectionDescription = "Caution: Obstacle in path"
            } else {
                self.decision = "GO"
                
                if !self.detectedText.isEmpty {
                    // Just mention the first 1-2 text items if present
                    let textSummary = Array(self.detectedText.prefix(2)).joined(separator: ", ")
                    self.detectionDescription = "Path clear. Text visible: \(textSummary)"
                } else {
                    self.detectionDescription = "Path clear"
                }
            }
        }
    }
    
    func speakFeedback() {
        let utterance = AVSpeechUtterance(string: "\(decision). \(detectionDescription)")
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
