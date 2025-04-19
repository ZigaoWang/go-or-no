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
                .padding(.bottom, 50)
                
                // Target indicator in center
                Image(systemName: "target")
                    .font(.system(size: 50))
                    .foregroundColor(.red.opacity(0.7))
                
                Spacer()

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
    @Published var soundEnabled: Bool = true

    let arSession = ARSession()
    private var timer: Timer? = nil
    private let feedbackGenerator = UIImpactFeedbackGenerator(style: .medium)

    override init() {
        super.init()
        configureAudioSession() // Configure audio session at init
        setupARSession()
    }

    // Configure the shared AVAudioSession
    private func configureAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            // Change category to .playback to ignore silent switch
            try audioSession.setCategory(.playback, mode: .default, options: [.mixWithOthers]) // Allow mixing, ignore silent switch
            try audioSession.setActive(true)
            print("Audio session configured for playback (ignores silent switch).")
        } catch {
            print("ERROR: Failed to configure AVAudioSession: \\(error)")
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
    }

    // Renamed function for clarity
    private func startFeedbackTimer() {
        feedbackGenerator.prepare() // Prepare haptics generator

        timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in // 50Hz timer
            guard let self = self else { return }

            let distance = self.currentDistance
            if distance > 0 {
                let interval = self.calculateVibrationInterval(for: distance)
                let currentTime = Date().timeIntervalSince1970
                let shouldTrigger = Int(currentTime * 50) % max(Int(interval * 50), 1) == 0
                let isVeryClose = interval <= 0.016 // Adjusted threshold slightly for 66Hz target

                if isVeryClose || shouldTrigger {
                    // Trigger Vibration if enabled
                    if self.vibrationEnabled {
                        self.feedbackGenerator.impactOccurred()
                        self.feedbackGenerator.prepare() // Re-prepare for next haptic
                    }

                    // Trigger System Sound if enabled
                    if self.soundEnabled {
                        print("Playing sound... (ID: 1104)") // Add logging
                        // Use keyboard tick sound - rapid repetition might sound like "di di di"
                        AudioServicesPlaySystemSound(1104) // Changed back to 1104
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
        // Check if depth data is available
        guard let depthData = frame.sceneDepth else { return }
        
        // Get the depth at the center of the frame
        let width = CVPixelBufferGetWidth(depthData.depthMap)
        let height = CVPixelBufferGetHeight(depthData.depthMap)
        let centerX = width / 2
        let centerY = height / 2
        
        if let depth = getDepthFromBuffer(depthData.depthMap, atPoint: (centerX, centerY)) {
            DispatchQueue.main.async {
                self.currentDistance = depth
            }
        }
    }
    
    private func getDepthFromBuffer(_ depthMap: CVPixelBuffer, atPoint point: (Int, Int)) -> Double? {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        
        // Get buffer dimensions
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        
        // Ensure point is within bounds
        guard point.0 >= 0, point.0 < width, point.1 >= 0, point.1 < height else {
            return nil
        }
        
        // Get a pointer to the depth data
        let baseAddress = CVPixelBufferGetBaseAddress(depthMap)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let depthPointer = baseAddress!.advanced(by: point.1 * bytesPerRow + point.0 * MemoryLayout<Float32>.size).assumingMemoryBound(to: Float32.self)
        
        // Get the depth value (in meters)
        let depth = Double(depthPointer.pointee)
        
        // Return nil if depth is invalid (0 or infinity)
        guard depth > 0, depth.isFinite else {
            return nil
        }
        
        return depth
    }
}

#Preview {
    ContentView()
}
