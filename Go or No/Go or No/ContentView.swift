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
                    // Dynamic target size based on slider
                    .overlay(
                        Rectangle()
                            .stroke(Color.yellow.opacity(0.5), lineWidth: 2)
                            .frame(width: min(UIScreen.main.bounds.width, UIScreen.main.bounds.height) * viewModel.focusAreaSize,
                                   height: min(UIScreen.main.bounds.width, UIScreen.main.bounds.height) * viewModel.focusAreaSize)
                    )
                
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
    @Published var focusAreaSize: CGFloat = 0.50

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
                        // REMOVED prepare() call from here
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
}

#Preview {
    ContentView()
}
