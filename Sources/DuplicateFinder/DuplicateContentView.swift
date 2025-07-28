import SwiftUI
import Photos

public struct DuplicateContentView: View {
    @StateObject private var photoManager = PhotoLibraryManager()
    @State private var showingDuplicates = false
    @State private var isScanning = false
    @State private var showingScanOptions = false
    @State private var selectedScanType: PhotoLibraryManager.ScanType = .full
    @State private var showingPerformanceInfo = false
    
    public init() {}
    @State private var scanStartTime: Date?
    @State private var elapsedTime: TimeInterval = 0
    @State private var timer: Timer?
    @State private var lastScanDuration: TimeInterval = 0
    
    public var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "photo.stack")
                        .font(.system(size: 80))
                        .foregroundColor(.blue)
                    
                    Text("Doppel Gallery")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    
                    Text("Your Gallery’s Doppelgänger Detector")
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                    
                    // Show last scan info if available
                    if let lastScanDate = photoManager.lastScanDate {
                        VStack(spacing: 8) {
                            HStack {
                                Image(systemName: "clock")
                                    .foregroundColor(.blue)
                                Text("Last scan: \(DateFormatter.scanDate.string(from: lastScanDate))")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            
                            HStack {
                                Image(systemName: "photo")
                                    .foregroundColor(.blue)
                                Text("\(photoManager.totalAssetsScanned) assets scanned")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            
                            if photoManager.newAssetsSinceLastScan > 0 {
                                HStack {
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundColor(.orange)
                                    Text("\(photoManager.newAssetsSinceLastScan) new assets since last scan")
                                        .font(.subheadline)
                                        .foregroundColor(.orange)
                                }
                            }
                            
                            // Performance info
                            HStack {
                                Image(systemName: "speedometer")
                                    .foregroundColor(.gray)
                                Text(photoManager.getPerformanceStats())
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                        }
                        .padding()
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(12)
                    }
                    
                    VStack(spacing: 16) {
                        if photoManager.authorizationStatus == .authorized {
                            // Scan options
                            if photoManager.lastScanDate != nil && photoManager.newAssetsSinceLastScan > 0 {
                                // Show both full and delta scan options
                                VStack(spacing: 12) {
                                    Button(action: {
                                        selectedScanType = .delta
                                        Task {
                                            startScanTimer()
                                            isScanning = true
                                            await photoManager.scanForDuplicates(scanType: .delta)
                                            isScanning = false
                                            stopScanTimer()
                                            showingDuplicates = true
                                        }
                                    }) {
                                        HStack {
                                            if isScanning && selectedScanType == .delta {
                                                ProgressView()
                                                    .scaleEffect(0.8)
                                                    .padding(.trailing, 4)
                                            }
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(isScanning && selectedScanType == .delta ? "Quick Scanning..." : "Quick Scan (New Photos)")
                                                    .fontWeight(.medium)
                                                Text("Only scan \(photoManager.newAssetsSinceLastScan) new photos (~\(estimatedTime(for: photoManager.newAssetsSinceLastScan)))")
                                                    .font(.caption)
                                                    .opacity(0.8)
                                            }
                                            Spacer()
                                            Image(systemName: "bolt.fill")
                                        }
                                        .frame(maxWidth: .infinity)
                                        .padding()
                                        .background(Color.orange)
                                        .foregroundColor(.white)
                                        .cornerRadius(12)
                                    }
                                    .disabled(isScanning)
                                    
                                    Button(action: {
                                        selectedScanType = .full
                                        Task {
                                            startScanTimer()
                                            isScanning = true
                                            await photoManager.scanForDuplicates(scanType: .full)
                                            isScanning = false
                                            stopScanTimer()
                                            showingDuplicates = true
                                        }
                                    }) {
                                        HStack {
                                            if isScanning && selectedScanType == .full {
                                                ProgressView()
                                                    .scaleEffect(0.8)
                                                    .padding(.trailing, 4)
                                            }
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(isScanning && selectedScanType == .full ? "Full Scanning..." : "Full Scan (All Photos)")
                                                    .fontWeight(.medium)
                                                Text("Scan entire photo library (~\(estimatedTime(for: photoManager.totalAssetsScanned > 0 ? photoManager.totalAssetsScanned : 1000)))")
                                                    .font(.caption)
                                                    .opacity(0.8)
                                            }
                                            Spacer()
                                            Image(systemName: "magnifyingglass")
                                        }
                                        .frame(maxWidth: .infinity)
                                        .padding()
                                        .background(Color.blue)
                                        .foregroundColor(.white)
                                        .cornerRadius(12)
                                    }
                                    .disabled(isScanning)
                                }
                            } else {
                                // Single scan button (first time or no new assets)
                                Button(action: {
                                    selectedScanType = .full
                                    Task {
                                        startScanTimer()
                                        isScanning = true
                                        await photoManager.scanForDuplicates(scanType: .full)
                                        isScanning = false
                                        stopScanTimer()
                                        showingDuplicates = true
                                    }
                                }) {
                                    HStack {
                                        if isScanning {
                                            ProgressView()
                                                .scaleEffect(0.8)
                                                .padding(.trailing, 4)
                                        }
                                        Text(isScanning ? "Scanning..." : photoManager.lastScanDate == nil ? "Scan for Duplicates" : "Rescan All Photos")
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(Color.blue)
                                    .foregroundColor(.white)
                                    .cornerRadius(12)
                                }
                                .disabled(isScanning)
                            }
                            
                            if !photoManager.duplicateGroups.isEmpty {
                                VStack(spacing: 8) {
                                    NavigationLink(destination: DuplicateListView(photoManager: photoManager)) {
                                        HStack {
                                            Text("View Duplicates")
                                            Spacer()
                                            Text("\(photoManager.duplicateGroups.count) groups")
                                                .foregroundColor(.secondary)
                                        }
                                        .frame(maxWidth: .infinity)
                                        .padding()
                                        .background(Color.green)
                                        .foregroundColor(.white)
                                        .cornerRadius(12)
                                    }
                                    
                                    if lastScanDuration > 0 {
                                        HStack(spacing: 4) {
                                            Image(systemName: "clock.badge.checkmark")
                                                .font(.caption)
                                                .foregroundColor(.green)
                                            
                                            Text("Scan completed in \(formatElapsedTime(lastScanDuration))")
                                                .font(.caption)
                                                .foregroundColor(.green)
                                                .fontWeight(.medium)
                                        }
                                    }
                                }
                            } else if photoManager.duplicateGroups.isEmpty && photoManager.hasCompletedScan {
                                // Show success message when scan completed but no duplicates found
                                VStack(spacing: 8) {
                                    HStack {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.green)
                                        Text("No duplicates found!")
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(Color.green.opacity(0.1))
                                    .cornerRadius(12)
                                    
                                    if lastScanDuration > 0 {
                                        HStack(spacing: 4) {
                                            Image(systemName: "clock.badge.checkmark")
                                                .font(.caption)
                                                .foregroundColor(.green)
                                            
                                            Text(formatElapsedTime(lastScanDuration))
                                                .font(.caption)
                                                .foregroundColor(.green)
                                                .fontWeight(.medium)
                                        }
                                    }
                                }
                            }
                        } else {
                            Button("Grant Photo Access") {
                                photoManager.requestPhotoLibraryAccess()
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.orange)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                        }
                    }
                    .padding(.horizontal)
                    
                    Spacer()
                    
                    if isScanning {
                        VStack(spacing: 8) {
                            ProgressView(value: photoManager.scanProgress)
                                .progressViewStyle(LinearProgressViewStyle())
                            
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 8) {
                                        Text("Scanning \(Int(photoManager.scanProgress * 100))%")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        
                                        Text("•")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        
                                        HStack(spacing: 3) {
                                            Image(systemName: "clock")
                                                .font(.caption2)
                                                .foregroundColor(.blue)
                                            
                                            Text(formatElapsedTime(elapsedTime))
                                                .font(.caption)
                                                .foregroundColor(.blue)
                                                .fontWeight(.medium)
                                                .monospacedDigit()
                                        }
                                    }
                                    
                                    if !photoManager.currentScanPhase.isEmpty {
                                        Text(photoManager.currentScanPhase)
                                            .font(.caption2)
                                            .foregroundColor(.blue)
                                    }
                                }
                                
                                Spacer()
                                
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(selectedScanType == .delta ? "Quick Scan" : "Full Scan")
                                        .font(.caption)
                                        .foregroundColor(.blue)
                                    
                                    if elapsedTime > 0 {
                                        HStack(spacing: 2) {
                                            Image(systemName: "hourglass")
                                                .font(.caption2)
                                                .foregroundColor(.orange)
                                            
                                            Text("~\(estimatedTimeRemaining())")
                                                .font(.caption2)
                                                .foregroundColor(.orange)
                                                .monospacedDigit()
                                        }
                                    }
                                }
                            }
                            
                            if photoManager.scanProgress > 0.1 {
                                HStack {
                                    Text("Ultra-fast algorithm - \(photoManager.getPerformanceStats())")
                                        .font(.caption2)
                                        .foregroundColor(.gray)
                                    
                                    Spacer()
                                    
                                    if elapsedTime > 1 && photoManager.scanProgress > 0.05 {
                                        let assetsPerSecond = Int(Double(photoManager.totalAssetsScanned) * photoManager.scanProgress / elapsedTime)
                                        Text("\(assetsPerSecond) assets/sec")
                                            .font(.caption2)
                                            .foregroundColor(.green)
                                            .fontWeight(.medium)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
            .navigationTitle("Doppel Gallery")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button(action: {
                        showingPerformanceInfo = true
                    }) {
                        Image(systemName: "speedometer")
                    }
                    
                    if photoManager.lastScanDate != nil {
                        Menu {
                            Button("Clear Scan History") {
                                photoManager.clearStoredResults()
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
            .onAppear {
                photoManager.checkAuthorizationStatus()
            }
            .onDisappear {
                stopScanTimer()
            }
            .sheet(isPresented: $showingPerformanceInfo) {
                PerformanceInfoView()
            }
        }
    }
}

extension DuplicateContentView {
    private func estimatedTime(for assetCount: Int) -> String {
        return photoManager.getSpeedEstimate(for: assetCount)
    }
    
    private func startScanTimer() {
        scanStartTime = Date()
        elapsedTime = 0
        
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            if let startTime = scanStartTime {
                elapsedTime = Date().timeIntervalSince(startTime)
            }
        }
    }
    
    private func stopScanTimer() {
        if let startTime = scanStartTime {
            lastScanDuration = Date().timeIntervalSince(startTime)
        }
        
        timer?.invalidate()
        timer = nil
        scanStartTime = nil
    }
    
    private func formatElapsedTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        let milliseconds = Int((time.truncatingRemainder(dividingBy: 1)) * 10)
        
        if minutes > 0 {
            return String(format: "%d:%02d", minutes, seconds)
        } else {
            return String(format: "%d.%ds", seconds, milliseconds)
        }
    }
    
    private func estimatedTimeRemaining() -> String {
        guard photoManager.scanProgress > 0.05 && elapsedTime > 1 else {
            return "calculating..."
        }
        
        let estimatedTotal = elapsedTime / photoManager.scanProgress
        let remaining = max(0, estimatedTotal - elapsedTime)
        
        let minutes = Int(remaining) / 60
        let seconds = Int(remaining) % 60
        
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        } else {
            return "\(seconds)s"
        }
    }
} 
