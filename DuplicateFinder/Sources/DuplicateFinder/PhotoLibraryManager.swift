import Foundation
import Photos
import UIKit
import CryptoKit
import SwiftUI
import CoreLocation

// MARK: - Performance Optimized Models
struct AssetMetadata {
    let asset: PHAsset
    let identifier: String
    let mediaType: PHAssetMediaType
    let pixelWidth: Int
    let pixelHeight: Int
    let duration: TimeInterval
    let creationDate: Date?
    let fileSize: Int64
    let location: CLLocation?
    let cameraMake: String?
    let cameraModel: String?
    
    init(asset: PHAsset) {
        self.asset = asset
        self.identifier = asset.localIdentifier
        self.mediaType = asset.mediaType
        self.pixelWidth = asset.pixelWidth
        self.pixelHeight = asset.pixelHeight
        self.duration = asset.duration
        self.creationDate = asset.creationDate
        self.location = asset.location
        
        // Get camera info if available (will be populated later when metadata is extracted)
        self.cameraMake = nil
        self.cameraModel = nil
        
        // Get accurate file size
        if let resource = PHAssetResource.assetResources(for: asset).first {
            let unsignedInt64 = resource.value(forKey: "fileSize") as? CLong ?? 0
            self.fileSize = Int64(unsignedInt64)
        } else {
            self.fileSize = 0
        }
    }
    
    func metadataKey() -> String {
        if mediaType == .video {
            // For videos, include duration in the key with 1-second precision
            return "\(mediaType.rawValue)_\(pixelWidth)_\(pixelHeight)_\(Int(duration))"
        } else {
            // For images, just use dimensions
            return "\(mediaType.rawValue)_\(pixelWidth)_\(pixelHeight)"
        }
    }
    
    func quickMatchKey() -> String {
        // Even more specific grouping for faster processing
        if mediaType == .video {
            // Round duration to nearest second for videos
            let roundedDuration = Int(duration)
            return "\(mediaType.rawValue)_\(pixelWidth)_\(pixelHeight)_\(roundedDuration)"
        } else {
            // For images, include file size range
            let sizeCategory = fileSize / (100 * 1024) // Group by 100KB ranges
            return "\(mediaType.rawValue)_\(pixelWidth)_\(pixelHeight)_\(sizeCategory)"
        }
    }
}

@MainActor
public class PhotoLibraryManager: ObservableObject {
    @Published var authorizationStatus: PHAuthorizationStatus = .notDetermined
    @Published var duplicateGroups: [DuplicateGroup] = []
    @Published var scanProgress: Double = 0.0
    @Published var hasCompletedScan: Bool = false
    @Published var lastScanDate: Date?
    @Published var totalAssetsScanned: Int = 0
    @Published var newAssetsSinceLastScan: Int = 0
    @Published var currentScanPhase: String = ""
    @Published var isScanning: Bool = false
    @Published var scanStatus: String = ""
    @Published var totalAssetsCount: Int = 0
    @Published var processedAssetsCount: Int = 0
    @Published var errorMessage: String?
    
    private var allAssets: [PHAsset] = []
    private var lastAssetDate: Date?
    private let storage = ScanResultStorage()
    
    // Performance optimization caches
    private var assetMetadataCache: [String: AssetMetadata] = [:]
    private var thumbnailHashCache: [String: String] = [:]
    
    public enum ScanType {
        case full
        case delta
    }
    
    // Aggressive performance settings
    private let maxConcurrentTasks = 8
    private let batchSize = 100
    private let thumbnailSize = CGSize(width: 16, height: 16) // Much smaller for speed
    
    // Computed properties for organized duplicate groups
    var exactDuplicateGroups: [DuplicateGroup] {
        duplicateGroups.filter { $0.similarityType == .exact }
    }
    
    var similarItemGroups: [DuplicateGroup] {
        duplicateGroups.filter { $0.similarityType == .similar }
    }
    
    var hasExactDuplicates: Bool {
        !exactDuplicateGroups.isEmpty
    }
    
    var hasSimilarItems: Bool {
        !similarItemGroups.isEmpty
    }
    
    // MARK: - Scan Stats

    struct ScanStats {
        let totalAssetsScanned: Int
        let duplicatesFound: Int
        let duplicateGroups: Int
        let totalSize: Int64
        let scanDuration: TimeInterval
    }
    
    @Published var scanStats: ScanStats?
    
    private let imageManager = PHImageManager.default()
    private let metadataCache = NSCache<NSString, NSData>()
    
    // Configure prefetch options for asset metadata
    private let metadataPrefetchOptions: PHImageRequestOptions = {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .opportunistic
        options.isSynchronous = false
        return options
    }()
    
    public init() {
        loadStoredResults()
    }
    
    func checkAuthorizationStatus() {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }
    
    private func loadStoredResults() {
        if let storedResults = storage.loadScanResults() {
            duplicateGroups = storedResults.duplicateGroups
            lastScanDate = storedResults.scanDate
            totalAssetsScanned = storedResults.totalAssetsScanned
            lastAssetDate = storedResults.lastAssetDate
            hasCompletedScan = true
            
            // Check for new assets since last scan
            Task {
                await checkForNewAssets()
            }
        }
    }
    
    func requestPhotoLibraryAccess() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            DispatchQueue.main.async {
                self.authorizationStatus = status
            }
        }
    }
    
    func scanForDuplicates(scanType: ScanType = .full) async {
        guard authorizationStatus == .authorized else { return }
        
        switch scanType {
        case .full:
            await performFullScan()
        case .delta:
            await performDeltaScan()
        }
    }
    
    private func checkForNewAssets() async {
        guard let lastScanDate = lastScanDate else { return }
        
        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(format: "creationDate > %@", lastScanDate as NSDate)
        
        let newAssets = PHAsset.fetchAssets(with: fetchOptions)
        newAssetsSinceLastScan = newAssets.count
    }
    
    private func performFullScan() async {
        // Clear caches for fresh scan
        assetMetadataCache.removeAll()
        thumbnailHashCache.removeAll()
        
        await loadAllAssets()
        await findDuplicates()
        await saveResults()
    }
    
    private func performDeltaScan() async {
        guard let lastScanDate = lastScanDate else {
            // No previous scan, perform full scan
            await performFullScan()
            return
        }
        
        // Load new assets since last scan
        await loadNewAssets(since: lastScanDate)
        
        if allAssets.isEmpty {
            // No new assets, just refresh existing results
            await refreshDuplicateGroups()
            return
        }
        
        // Find duplicates in new assets and merge with existing results
        await findDuplicatesInNewAssets()
        await saveResults()
    }
    
    private func loadAllAssets() async {
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        
        // Configure fetch options for better performance
        fetchOptions.includeHiddenAssets = true
        fetchOptions.includeAllBurstAssets = false
        
        let assets = PHAsset.fetchAssets(with: fetchOptions)
        allAssets = []
        lastAssetDate = nil
        
        // Request additional properties to be prefetched
        if let firstAsset = assets.firstObject {
            PHAssetResource.assetResources(for: firstAsset)
        }
        
        assets.enumerateObjects { asset, _, _ in
            self.allAssets.append(asset)
            
            // Track the newest asset's date for incremental scanning
            if self.lastAssetDate == nil || asset.creationDate?.compare(self.lastAssetDate!) == .orderedDescending {
                self.lastAssetDate = asset.creationDate
            }
        }
        
        print("📸 Loaded \(allAssets.count) assets from photo library")
    }
    
    private func loadNewAssets(since date: Date) async {
        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(format: "creationDate > %@", date as NSDate)
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        
        // Configure fetch options for better performance
        fetchOptions.includeHiddenAssets = true
        fetchOptions.includeAllBurstAssets = false
        
        let assets = PHAsset.fetchAssets(with: fetchOptions)
        allAssets = []
        
        assets.enumerateObjects { asset, _, _ in
            self.allAssets.append(asset)
            
            // Update the last asset date if needed
            if self.lastAssetDate == nil || asset.creationDate?.compare(self.lastAssetDate!) == .orderedDescending {
                self.lastAssetDate = asset.creationDate
            }
        }
        
        print("📸 Loaded \(allAssets.count) new assets since \(date)")
    }
    
    private func findDuplicates() async {
        print("🚀 Starting duplicate detection for \(allAssets.count) assets")
        let startTime = Date()
        
        // Prefetch metadata for all assets to avoid main thread fetching
        prefetchAssetMetadata(for: allAssets)
        
        // Group assets by basic properties for faster comparison
        currentScanPhase = "Grouping assets by properties..."
        let assetGroups = groupAssetsByProperties()
        scanProgress = 0.1
        
        // Process each group to find duplicates
        currentScanPhase = "Analyzing potential duplicates..."
        var newDuplicateGroups: [DuplicateGroup] = []
        var processedGroups = 0
        
        for (_, group) in assetGroups {
            if group.count > 1 {
                // Find duplicates within this group
                if let duplicates = await findDuplicatesInGroup(group) {
                    newDuplicateGroups.append(duplicates)
                }
            }
            
            processedGroups += 1
            scanProgress = 0.1 + 0.9 * Double(processedGroups) / Double(assetGroups.count)
            
            // Allow UI to update periodically
            if processedGroups % 10 == 0 {
                await Task.yield()
            }
        }
        
        // Update the duplicate groups
        await MainActor.run {
            duplicateGroups = newDuplicateGroups
            
            // Calculate stats
            let totalDuplicates = duplicateGroups.reduce(0) { $0 + $1.items.count }
            let totalGroups = duplicateGroups.count
            let totalSize = duplicateGroups.reduce(0) { $0 + $1.totalSize }
            
            scanStats = ScanStats(
                totalAssetsScanned: allAssets.count,
                duplicatesFound: totalDuplicates,
                duplicateGroups: totalGroups,
                totalSize: totalSize,
                scanDuration: Date().timeIntervalSince(startTime)
            )
            
            isScanning = false
            scanProgress = 1.0
            currentScanPhase = "Scan complete"
        }
    }
    
    // Group assets by basic properties to reduce comparison space
    private func groupAssetsByProperties() -> [String: [PHAsset]] {
        var groups: [String: [PHAsset]] = [:]
        
        for asset in allAssets {
            // Create a key based on asset properties with more precision
            let key: String
            
            if asset.mediaType == .video {
                // For videos, include duration rounded to nearest second
                key = "\(asset.mediaType.rawValue)_\(asset.pixelWidth)_\(asset.pixelHeight)_\(Int(asset.duration))"
            } else {
                // For images, group by dimensions and aspect ratio category
                let aspectRatio = Double(asset.pixelWidth) / Double(asset.pixelHeight)
                let aspectCategory = Int(aspectRatio * 10) // Group similar aspect ratios
                key = "\(asset.mediaType.rawValue)_\(asset.pixelWidth)_\(asset.pixelHeight)_\(aspectCategory)"
            }
            
            if groups[key] == nil {
                groups[key] = []
            }
            groups[key]?.append(asset)
        }
        
        return groups
    }
    
    // MARK: - Video Processing

    // Extract video keyframe for comparison
    private func extractVideoKeyframe(_ asset: PHAsset) async -> UIImage? {
        guard asset.mediaType == .video else { return nil }
        
        return await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.version = .original
            options.deliveryMode = .fastFormat
            
            // Request a still image at 10% of the video duration
            let timeInSeconds = asset.duration * 0.1
            let time = CMTime(seconds: timeInSeconds, preferredTimescale: 600)
            
            // Use a single image request with proper options
            let requestOptions = PHImageRequestOptions()
            requestOptions.deliveryMode = .highQualityFormat
            requestOptions.resizeMode = .exact
            requestOptions.isNetworkAccessAllowed = false
            requestOptions.isSynchronous = false
            
            // Track if we've already resumed to prevent multiple resumes
            var hasResumed = false
            
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 128, height: 128),
                contentMode: .aspectFit,
                options: requestOptions
            ) { image, info in
                // Only resume once
                guard !hasResumed else { return }
                
                hasResumed = true
                continuation.resume(returning: image)
            }
        }
    }

    // Compare videos by duration and keyframe similarity
    private func areVideosEqual(_ asset1: PHAsset, _ asset2: PHAsset) async -> (Bool, Double) {
        // Check duration first (must be very close for exact duplicates)
        let durationDiff = abs(asset1.duration - asset2.duration)
        let maxDuration = max(asset1.duration, asset2.duration)
        
        // For exact duplicates, duration should be within 0.1 seconds or 0.1% of total duration
        let exactDurationThreshold = min(0.1, maxDuration * 0.001)
        
        // For similar videos, allow up to 0.5 seconds or 1% difference
        let similarDurationThreshold = min(0.5, maxDuration * 0.01)
        
        // Check dimensions
        let dimensionMatch = asset1.pixelWidth == asset2.pixelWidth && asset1.pixelHeight == asset2.pixelHeight
        
        // Check location if available
        var locationConfidence = 1.0
        if let loc1 = asset1.location, let loc2 = asset2.location {
            let distance = loc1.distance(from: loc2)
            if distance > 100 { // If more than 100 meters apart
                // Adjust confidence based on distance
                locationConfidence = min(1.0, 1000.0 / (distance + 1000.0)) // Normalize with 1km reference
            }
        }
        
        // Extract keyframes for visual comparison
        let keyframe1 = await extractVideoKeyframe(asset1)
        let keyframe2 = await extractVideoKeyframe(asset2)
        
        if let frame1 = keyframe1, let frame2 = keyframe2 {
            // Compare keyframes
            let hash1 = fastPerceptualHash(frame1)
            let hash2 = fastPerceptualHash(frame2)
            
            let distance = hammingDistance(hash1, hash2)
            let normalizedDistance = Double(distance) / Double(hash1.count)
            
            // Calculate visual confidence
            let visualConfidence = 1.0 - (normalizedDistance / 0.2)
            
            // Exact match: duration very close, dimensions match, and keyframes nearly identical
            if durationDiff <= exactDurationThreshold && dimensionMatch && normalizedDistance < 0.05 && locationConfidence > 0.9 {
                return (true, locationConfidence * 0.2 + 0.8) // Exact duplicate with location-adjusted confidence
            }
            
            // Similar match: duration somewhat close and keyframes somewhat similar
            if durationDiff <= similarDurationThreshold && normalizedDistance < 0.2 {
                // Calculate confidence based on duration, visual similarity, and location
                let durationConfidence = 1.0 - (durationDiff / similarDurationThreshold)
                let confidence = (durationConfidence * 0.4) + (visualConfidence * 0.4) + (locationConfidence * 0.2)
                return (false, confidence) // Similar with calculated confidence
            }
        }
        
        return (false, 0.0) // Not similar
    }

    // Find duplicates within a group of assets with similar properties (PHAsset version)
    private func findDuplicatesInGroup(_ assets: [PHAsset]) async -> DuplicateGroup? {
        guard assets.count > 1 else { return nil }
        
        // Create items for each asset
        var items: [DuplicateItem] = []
        var exactDuplicates = true
        var matchConfidence = 1.0
        
        // First, get accurate file sizes and create metadata for comparison
        var assetData: [(asset: PHAsset, size: Int64, hash: String?, location: CLLocation?, cameraMake: String?, cameraModel: String?)] = []
        
        for asset in assets {
            // Get accurate file size
            var fileSize: Int64 = 0
            if let resource = PHAssetResource.assetResources(for: asset).first {
                let unsignedInt64 = resource.value(forKey: "fileSize") as? CLong ?? 0
                fileSize = Int64(unsignedInt64)
            }
            
            // For images, compute hash for content-based comparison
            var hash: String? = nil
            if asset.mediaType == .image {
                hash = await getPerceptualHash(asset)
            }
            
            // Extract camera info from asset metadata if possible
            var cameraMake: String? = nil
            var cameraModel: String? = nil
            
            // We'll extract this information later when creating the DuplicateItem
            
            assetData.append((asset, fileSize, hash, asset.location, cameraMake, cameraModel))
        }
        
        // Group assets by file size first (exact duplicates must have same size)
        let groupedBySize = Dictionary(grouping: assetData) { $0.size }
        
        // Find the largest group with the same file size
        if let (_, sameSize) = groupedBySize.max(by: { $0.value.count < $1.value.count }) {
            // If we have multiple assets with the same file size
            if sameSize.count > 1 {
                // For images, verify content similarity using perceptual hashes
                if sameSize[0].asset.mediaType == .image {
                    // Compare perceptual hashes
                    let referenceHash = sameSize[0].hash
                    
                    // Check if all hashes match closely enough
                    for i in 1..<sameSize.count {
                        if let hash1 = referenceHash, let hash2 = sameSize[i].hash {
                            let distance = hammingDistance(hash1, hash2)
                            let normalizedDistance = Double(distance) / Double(hash1.count)
                            
                            if normalizedDistance > 0.05 { // Allow very small differences for exact duplicates
                                exactDuplicates = false
                                matchConfidence = max(0.85, 1.0 - normalizedDistance)
                                break
                            }
                        } else {
                            exactDuplicates = false
                            matchConfidence = 0.85
                            break
                        }
                        
                        // Compare locations if available
                        if let loc1 = sameSize[0].location, let loc2 = sameSize[i].location {
                            let distance = loc1.distance(from: loc2)
                            if distance > 100 { // If more than 100 meters apart
                                exactDuplicates = false
                                // Adjust confidence based on distance
                                let locationConfidence = min(1.0, 1000.0 / (distance + 1000.0)) // Normalize with 1km reference
                                matchConfidence = min(matchConfidence, 0.9 * locationConfidence + 0.1)
                            }
                        }
                        
                        // Compare device models if available
                        if let model1 = sameSize[0].cameraModel, let model2 = sameSize[i].cameraModel, model1 != model2 {
                            exactDuplicates = false
                            matchConfidence = min(matchConfidence, 0.9) // Different devices reduce confidence slightly
                        }
                    }
                } else if sameSize[0].asset.mediaType == .video {
                    // For videos, compare duration and content
                    let referenceAsset = sameSize[0].asset
                    
                    // Compare each video against the reference
                    for i in 1..<sameSize.count {
                        let (isExact, confidence) = await areVideosEqual(referenceAsset, sameSize[i].asset)
                        if !isExact {
                            exactDuplicates = false
                            matchConfidence = min(matchConfidence, confidence)
                        }
                        
                        // Compare locations if available
                        if let loc1 = sameSize[0].location, let loc2 = sameSize[i].location {
                            let distance = loc1.distance(from: loc2)
                            if distance > 100 { // If more than 100 meters apart
                                exactDuplicates = false
                                // Adjust confidence based on distance
                                let locationConfidence = min(1.0, 1000.0 / (distance + 1000.0)) // Normalize with 1km reference
                                matchConfidence = min(matchConfidence, confidence * 0.9 + locationConfidence * 0.1)
                            }
                        }
                    }
                }
                
                // Create DuplicateItems for the matching assets
                for (asset, fileSize, _, _, _, _) in sameSize {
                    let mediaType: AssetMediaType = asset.mediaType == .image ? .image : .video
                    
                    // Create a more accurate fingerprint
                    let fingerprint = FileFingerprint(
                        fileHash: asset.localIdentifier,
                        fileSize: fileSize,
                        mediaType: mediaType,
                        imageHash: nil
                    )
                    
                    // Create duplicate item
                    let item = DuplicateItem(asset: asset, fingerprint: fingerprint)
                    items.append(item)
                }
                
                // Determine similarity type based on our analysis
                let similarityType: SimilarityType = exactDuplicates ? .exact : .similar
                
                // Create and return the group
                return DuplicateGroup(items: items, similarityType: similarityType, matchConfidence: matchConfidence)
            }
        }
        
        return nil
    }
    
    // Helper to get asset size with more accuracy
    private func getAssetSize(_ asset: PHAsset) -> Int64 {
        // Try to get actual file size first
        if let resource = PHAssetResource.assetResources(for: asset).first {
            let unsignedInt64 = resource.value(forKey: "fileSize") as? CLong ?? 0
            return Int64(unsignedInt64)
        }
        
        // Fall back to estimation if needed
        let baseSize: Int64
        
        if asset.mediaType == .image {
            // Estimate image size based on resolution
            baseSize = Int64(asset.pixelWidth * asset.pixelHeight * 4) // 4 bytes per pixel (RGBA)
        } else {
            // Estimate video size based on duration and resolution
            baseSize = Int64(asset.duration * Double(asset.pixelWidth * asset.pixelHeight) * 0.1)
        }
        
        return max(baseSize, 1024 * 1024) // Minimum 1MB
    }
    
    // MARK: - Asset Metadata Prefetching
    
    private func prefetchAssetMetadata(for assets: [PHAsset]) {
        guard !assets.isEmpty else { return }
        
        // Process in smaller batches to avoid memory pressure
        let batchSize = 50
        for batch in assets.chunked(into: batchSize) {
            // Create a batch request to prefetch metadata
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = false
            options.isSynchronous = false
            options.deliveryMode = .fastFormat
            
            for asset in batch {
                // Access common properties to prefetch them
                _ = asset.creationDate
                _ = asset.location
                _ = asset.mediaType
                _ = asset.pixelWidth
                _ = asset.pixelHeight
                
                // Prefetch resources
                _ = PHAssetResource.assetResources(for: asset)
            }
        }
    }
    
    // Find duplicates for a single asset against existing groups
    private func findDuplicatesForSingleAsset(_ asset: PHAsset, existingGroups: inout [DuplicateGroup]) {
        // Get basic properties
        let mediaType: AssetMediaType = asset.mediaType == .image ? .image : .video
        
        // Get accurate file size
        var fileSize: Int64 = 0
        if let resource = PHAssetResource.assetResources(for: asset).first {
            let unsignedInt64 = resource.value(forKey: "fileSize") as? CLong ?? 0
            fileSize = Int64(unsignedInt64)
        } else {
            fileSize = getAssetSize(asset)
        }
        
        // Create a fingerprint
        let fingerprint = FileFingerprint(
            fileHash: asset.localIdentifier,
            fileSize: fileSize,
            mediaType: mediaType,
            imageHash: nil
        )
        
        // Create duplicate item
        let item = DuplicateItem(asset: asset, fingerprint: fingerprint)
        
        // Check against existing groups - non-async checks only
        for (index, group) in existingGroups.enumerated() {
            // Check if this asset might be a duplicate of any in this group
            if group.items.first?.fingerprint.mediaType == fingerprint.mediaType {
                // Get the first item in the group for comparison
                if let firstItem = group.items.first, let firstAsset = firstItem.asset {
                    // Skip if media types don't match
                    if firstAsset.mediaType != asset.mediaType {
                        continue
                    }
                    
                    // For exact duplicates, require exact file size match
                    if group.similarityType == .exact {
                        // File size must be very close
                        let sizeDiff = abs(Double(firstItem.fingerprint.fileSize - fingerprint.fileSize)) / Double(max(firstItem.fingerprint.fileSize, fingerprint.fileSize))
                        
                        // If size is exactly the same, consider it a potential exact duplicate
                        if sizeDiff < 0.01 { // 1% tolerance for exact duplicates
                            // For videos, simple duration check (non-async)
                            if asset.mediaType == .video {
                                let durationDiff = abs(asset.duration - firstAsset.duration)
                                if durationDiff < 0.1 { // 100ms tolerance
                                    // Add to this group
                                    var updatedItems = group.items
                                    updatedItems.append(item)
                                    existingGroups[index] = DuplicateGroup(items: updatedItems, similarityType: .exact)
                                }
                            }
                        }
                    }
                }
            }
        }
        
        // For more complex similarity checks that require async operations,
        // we'll need to use a different approach to avoid capturing inout parameters
    }
    
    // Async version for checking a single asset against existing groups
    private func checkAssetSimilarityAsync(_ asset: PHAsset, against groups: [DuplicateGroup]) async -> [(index: Int, updatedGroup: DuplicateGroup)] {
        var results: [(index: Int, updatedGroup: DuplicateGroup)] = []
        
        // Get basic properties
        let mediaType: AssetMediaType = asset.mediaType == .image ? .image : .video
        
        // Get accurate file size
        var fileSize: Int64 = 0
        if let resource = PHAssetResource.assetResources(for: asset).first {
            let unsignedInt64 = resource.value(forKey: "fileSize") as? CLong ?? 0
            fileSize = Int64(unsignedInt64)
        } else {
            fileSize = getAssetSize(asset)
        }
        
        // Create a fingerprint
        let fingerprint = FileFingerprint(
            fileHash: asset.localIdentifier,
            fileSize: fileSize,
            mediaType: mediaType,
            imageHash: nil
        )
        
        // Create duplicate item
        let item = DuplicateItem(asset: asset, fingerprint: fingerprint)
        
        // Check each group
        for (index, group) in groups.enumerated() {
            if group.items.first?.fingerprint.mediaType == fingerprint.mediaType {
                if let firstItem = group.items.first, let firstAsset = firstItem.asset {
                    // Skip if media types don't match
                    if firstAsset.mediaType != asset.mediaType {
                        continue
                    }
                    
                    // For exact duplicates with matching file size
                    if group.similarityType == .exact {
                        let sizeDiff = abs(Double(firstItem.fingerprint.fileSize - fingerprint.fileSize)) / Double(max(firstItem.fingerprint.fileSize, fingerprint.fileSize))
                        
                        if sizeDiff < 0.01 { // 1% tolerance for exact duplicates
                            if asset.mediaType == .image {
                                // For images, compare perceptual hashes
                                let hash1 = await getPerceptualHash(firstAsset)
                                let hash2 = await getPerceptualHash(asset)
                                
                                if let hash1 = hash1, let hash2 = hash2 {
                                    let distance = hammingDistance(hash1, hash2)
                                    let normalizedDistance = Double(distance) / Double(hash1.count)
                                    
                                    // Very strict threshold for exact duplicates
                                    if normalizedDistance < 0.05 {
                                        // Create updated group
                                        var updatedItems = group.items
                                        updatedItems.append(item)
                                        let updatedGroup = DuplicateGroup(items: updatedItems, similarityType: .exact)
                                        results.append((index: index, updatedGroup: updatedGroup))
                                    }
                                }
                            } else if asset.mediaType == .video {
                                // For videos, check duration and content
                                let (isExact, _) = await areVideosEqual(firstAsset, asset)
                                if isExact {
                                    // Create updated group
                                    var updatedItems = group.items
                                    updatedItems.append(item)
                                    let updatedGroup = DuplicateGroup(items: updatedItems, similarityType: .exact)
                                    results.append((index: index, updatedGroup: updatedGroup))
                                }
                            }
                        }
                    } else {
                        // For similar items
                        if asset.mediaType == .image {
                            // For images, compare perceptual hashes with relaxed threshold
                            let hash1 = await getPerceptualHash(firstAsset)
                            let hash2 = await getPerceptualHash(asset)
                            
                            if let hash1 = hash1, let hash2 = hash2 {
                                let distance = hammingDistance(hash1, hash2)
                                let normalizedDistance = Double(distance) / Double(hash1.count)
                                
                                // Relaxed threshold for similar items
                                if normalizedDistance < 0.15 {
                                    // Calculate confidence
                                    let confidence = 1.0 - (normalizedDistance / 0.15)
                                    
                                    // Create updated group
                                    var updatedItems = group.items
                                    updatedItems.append(item)
                                    let updatedGroup = DuplicateGroup(
                                        items: updatedItems, 
                                        similarityType: .similar,
                                        matchConfidence: confidence
                                    )
                                    results.append((index: index, updatedGroup: updatedGroup))
                                }
                            }
                        } else if asset.mediaType == .video {
                            // For videos, check with relaxed criteria
                            let (isExact, confidence) = await areVideosEqual(firstAsset, asset)
                            
                            // Add if similar enough (confidence > 0.7)
                            if confidence > 0.7 {
                                // Create updated group
                                var updatedItems = group.items
                                updatedItems.append(item)
                                let updatedGroup = DuplicateGroup(
                                    items: updatedItems,
                                    similarityType: isExact ? .exact : .similar,
                                    matchConfidence: confidence
                                )
                                results.append((index: index, updatedGroup: updatedGroup))
                            }
                        }
                    }
                }
            }
        }
        
        return results
    }
    
    private func findDuplicatesInNewAssets() async {
        print("🔍 Finding duplicates in \(allAssets.count) new assets")
        let startTime = Date()
        
        // Prefetch metadata for new assets
        prefetchAssetMetadata(for: allAssets)
        
        // Group new assets by properties
        currentScanPhase = "Grouping new assets..."
        let assetGroups = groupAssetsByProperties()
        scanProgress = 0.1
        
        // Find duplicates within new assets
        currentScanPhase = "Finding duplicates in new assets..."
        var newGroups: [DuplicateGroup] = []
        var processedGroups = 0
        
        for (_, group) in assetGroups {
            if group.count > 1 {
                if let duplicates = await findDuplicatesInGroup(group) {
                    newGroups.append(duplicates)
                }
            }
            
            processedGroups += 1
            scanProgress = 0.1 + 0.4 * Double(processedGroups) / Double(assetGroups.count)
            
            if processedGroups % 10 == 0 {
                await Task.yield()
            }
        }
        
        // Check for duplicates between new assets and existing groups
        currentScanPhase = "Comparing with existing assets..."
        var updatedGroups = duplicateGroups
        
        // Process assets in batches to avoid memory pressure
        let assetBatches = allAssets.chunked(into: 10)
        var processedAssets = 0
        
        for batch in assetBatches {
            // Process basic checks first (non-async)
            for asset in batch {
                findDuplicatesForSingleAsset(asset, existingGroups: &updatedGroups)
            }
            
            // Then process async checks
            for asset in batch {
                let results = await checkAssetSimilarityAsync(asset, against: updatedGroups)
                
                // Apply updates
                for (index, updatedGroup) in results {
                    if index < updatedGroups.count {
                        updatedGroups[index] = updatedGroup
                    }
                }
            }
            
            processedAssets += batch.count
            scanProgress = 0.5 + 0.5 * Double(processedAssets) / Double(allAssets.count)
            
            // Allow UI to update periodically
            await Task.yield()
        }
        
        // Merge new groups with updated existing groups
        updatedGroups.append(contentsOf: newGroups)
        
        // Update UI
        await MainActor.run {
            duplicateGroups = updatedGroups
            
            // Calculate stats
            let totalDuplicates = duplicateGroups.reduce(0) { $0 + $1.items.count }
            let totalGroups = duplicateGroups.count
            let totalSize = duplicateGroups.reduce(0) { $0 + $1.totalSize }
            
            let scanStats = ScanStats(
                totalAssetsScanned: allAssets.count,
                duplicatesFound: totalDuplicates,
                duplicateGroups: totalGroups,
                totalSize: totalSize,
                scanDuration: Date().timeIntervalSince(startTime)
            )
            
            self.scanStats = scanStats
            isScanning = false
            hasCompletedScan = true
            scanProgress = 1.0
            currentScanPhase = "Scan complete"
        }
    }
    
    private func buildDeltaMetadataCache(_ assets: [PHAsset?]) async {
        for asset in assets.compactMap({ $0 }) {
            if assetMetadataCache[asset.localIdentifier] == nil {
                let metadata = AssetMetadata(asset: asset)
                assetMetadataCache[asset.localIdentifier] = metadata
            }
        }
    }
    
    private func groupDeltaAssetsByMetadata(newAssets: [PHAsset], allAssets: [PHAsset?]) -> [String: [AssetMetadata]] {
        var groups: [String: [AssetMetadata]] = [:]
        
        // Add all assets to groups
        for asset in allAssets.compactMap({ $0 }) {
            if let metadata = assetMetadataCache[asset.localIdentifier] {
                let key = metadata.metadataKey()
                if groups[key] == nil {
                    groups[key] = []
                }
                groups[key]?.append(metadata)
            }
        }
        
        // Filter to only groups that contain at least one new asset AND have 2+ total assets
        let newAssetIds = Set(newAssets.map { $0.localIdentifier })
        return groups.filter { group in
            group.value.count > 1 && group.value.contains { newAssetIds.contains($0.identifier) }
        }
    }
    
    private func findDuplicatesInDeltaGroups(_ metadataGroups: [String: [AssetMetadata]]) async -> [DuplicateGroup] {
        var allDuplicateGroups: [DuplicateGroup] = []
        let totalGroups = metadataGroups.count
        var processedGroups = 0
        
        // Process groups concurrently in batches
        let groupKeys = Array(metadataGroups.keys)
        let batches = groupKeys.chunked(into: batchSize)
        
        for batch in batches {
            await withTaskGroup(of: [DuplicateGroup].self) { group in
                for groupKey in batch {
                    if let metadataItems = metadataGroups[groupKey] {
                        group.addTask {
                            // Convert AssetMetadata to PHAsset objects
                            let assets = metadataItems.map { $0.asset }
                            if let duplicateGroup = await self.findDuplicatesInGroup(assets) {
                                return [duplicateGroup]
                            }
                            return []
                        }
                    }
                }
                
                for await duplicateGroups in group {
                    allDuplicateGroups.append(contentsOf: duplicateGroups)
                }
            }
            
            processedGroups += batch.count
            scanProgress = 0.2 + (0.8 * Double(processedGroups) / Double(totalGroups))
        }
        
        return allDuplicateGroups
    }
    
    private func removeDuplicateGroups(existingGroups: [DuplicateGroup], newGroups: [DuplicateGroup]) -> [DuplicateGroup] {
        var mergedGroups = existingGroups
        
        for newGroup in newGroups {
            let newAssetIds = Set(newGroup.items.map { $0.assetIdentifier })
            
            // Check if this new group overlaps with any existing group
            var foundOverlap = false
            for (index, existingGroup) in mergedGroups.enumerated() {
                let existingAssetIds = Set(existingGroup.items.map { $0.assetIdentifier })
                
                if !newAssetIds.isDisjoint(with: existingAssetIds) {
                    // Merge the groups
                    let allItems = existingGroup.items + newGroup.items.filter { newItem in
                        let newItemId = newItem.assetIdentifier
                        return !existingAssetIds.contains(newItemId)
                    }
                    mergedGroups[index] = DuplicateGroup(items: allItems, similarityType: existingGroup.similarityType)
                    foundOverlap = true
                    break
                }
            }
            
            if !foundOverlap {
                mergedGroups.append(newGroup)
            }
        }
        
        return mergedGroups
    }
    
    // MARK: - Result Storage
    
    private func saveResults() async {
        storage.saveScanResults(duplicateGroups, totalAssetsScanned: allAssets.count, lastAssetDate: lastAssetDate)
        await MainActor.run {
            self.lastScanDate = Date()
        }
    }
    
    func refreshDuplicateGroups() async {
        print("🔄 Refreshing duplicate groups...")
        let startTime = Date()
        
        // Remove deleted assets from current duplicate groups
        var updatedGroups: [DuplicateGroup] = []
        var totalItemsRemoved = 0
        
        // Process groups in batches to avoid UI hang
        let batchSize = 10
        let groupBatches = duplicateGroups.chunked(into: batchSize)
        
        for batch in groupBatches {
            // Process each batch
            var batchUpdatedGroups: [DuplicateGroup] = []
            
            // Create a set of all asset identifiers for faster lookup
            let allIdentifiers = batch.flatMap { $0.items.map { $0.assetIdentifier } }
            
            // Fetch all assets in one batch operation for better performance
            let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: allIdentifiers, options: nil)
            
            // Create a dictionary of existing assets for O(1) lookup
            var existingAssetMap = [String: Bool](minimumCapacity: allIdentifiers.count)
            fetchResult.enumerateObjects { (asset, _, _) in
                existingAssetMap[asset.localIdentifier] = true
            }
            
            // Process each group in the batch
            for group in batch {
                // Filter out items with deleted assets
                let validItems = group.items.filter { existingAssetMap[$0.assetIdentifier] == true }
                totalItemsRemoved += group.items.count - validItems.count
                
                // Only keep groups with at least 2 items
                if validItems.count >= 2 {
                    let updatedGroup = DuplicateGroup(
                        items: validItems,
                        similarityType: group.similarityType,
                        matchConfidence: group.matchConfidence
                    )
                    batchUpdatedGroups.append(updatedGroup)
                }
            }
            
            // Add updated groups from this batch
            updatedGroups.append(contentsOf: batchUpdatedGroups)
            
            // Allow UI to update between batches
            await Task.yield()
        }
        
        // Update the UI
        await MainActor.run {
            duplicateGroups = updatedGroups
            let duration = Date().timeIntervalSince(startTime)
            print("✅ Refreshed duplicate groups in \(String(format: "%.1f", duration))s - Removed \(totalItemsRemoved) deleted items")
        }
        
        // Save the updated results
        await saveResults()
    }
    
    private func areAssetsVisuallySimilar(_ asset1: PHAsset, _ asset2: PHAsset) async -> Bool {
        // For videos, use duration and creation date similarity with stricter checks
        if asset1.mediaType == .video && asset2.mediaType == .video {
            // Check for similar dimensions first
            let dimensionRatio1 = Double(asset1.pixelWidth) / Double(asset1.pixelHeight)
            let dimensionRatio2 = Double(asset2.pixelWidth) / Double(asset2.pixelHeight)
            let ratioDifference = abs(dimensionRatio1 - dimensionRatio2)
            
            if ratioDifference > 0.1 { // Allow 10% aspect ratio difference
                return false
            }
            
            // Check duration with stricter tolerance
            let durationDifference = abs(asset1.duration - asset2.duration)
            let maxDuration = max(asset1.duration, asset2.duration)
            let durationTolerance = min(0.5, maxDuration * 0.05) // 0.5 sec or 5% of duration
            
            if durationDifference > durationTolerance {
                return false
            }
            
            // Check file size similarity
            let size1 = getAssetSize(asset1)
            let size2 = getAssetSize(asset2)
            let sizeDiff = abs(Double(size1 - size2)) / Double(max(size1, size2))
            
            if sizeDiff > 0.2 { // 20% size difference max
                return false
            }
            
            return true
        }
        
        // For photos, use improved perceptual hashing
        if asset1.mediaType == .image && asset2.mediaType == .image {
            // Check dimensions first
            let dimensionRatio1 = Double(asset1.pixelWidth) / Double(asset1.pixelHeight)
            let dimensionRatio2 = Double(asset2.pixelWidth) / Double(asset2.pixelHeight)
            let ratioDifference = abs(dimensionRatio1 - dimensionRatio2)
            
            if ratioDifference > 0.1 { // Allow 10% aspect ratio difference
                return false
            }
            
            return await areImagesVisuallySimilarFast(asset1, asset2)
        }
        
        // Different media types are never similar
        return false
    }
    
    private func areImagesVisuallySimilarFast(_ asset1: PHAsset, _ asset2: PHAsset) async -> Bool {
        // Get cached hashes or compute them
        let hash1 = await getPerceptualHash(asset1)
        let hash2 = await getPerceptualHash(asset2)
        
        guard let hash1 = hash1, let hash2 = hash2 else { return false }
        
        // Compare perceptual hashes with stricter threshold
        let distance = hammingDistance(hash1, hash2)
        
        // Base similarity on hash distance
        let isVisuallySimlar = distance <= 4 // Stricter threshold (was 5)
        
        // Check location if available
        if let loc1 = asset1.location, let loc2 = asset2.location {
            let locationDistance = loc1.distance(from: loc2)
            
            // If images are visually similar but taken far apart (> 1km), 
            // they're likely not the same scene/subject
            if isVisuallySimlar && locationDistance > 1000 {
                return false
            }
            
            // If images are borderline similar but taken at same location,
            // consider them similar
            if distance <= 6 && locationDistance < 100 {
                return true
            }
        }
        
        return isVisuallySimlar
    }
    
    private func getPerceptualHash(_ asset: PHAsset) async -> String? {
        // Check cache first
        if let cachedHash = thumbnailHashCache[asset.localIdentifier] {
            return cachedHash
        }
        
        let hash = await computePerceptualHash(asset)
        
        // Cache the result
        if let hash = hash {
            thumbnailHashCache[asset.localIdentifier] = hash
        }
        
        return hash
    }
    
    private func computePerceptualHash(_ asset: PHAsset) async -> String? {
        return await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat // Use higher quality for better hash accuracy
            options.resizeMode = .exact
            options.isSynchronous = false
            options.isNetworkAccessAllowed = false // Don't download from iCloud for speed
            
            // Use larger thumbnail for better accuracy
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 128, height: 128), // Larger size for better hash quality
                contentMode: .aspectFit, // Use aspectFit to preserve aspect ratio
                options: options
            ) { image, _ in
                guard let image = image else {
                    continuation.resume(returning: nil)
                    return
                }
                
                let hash = self.fastPerceptualHash(image)
                continuation.resume(returning: hash)
            }
        }
    }
    
    private func fastPerceptualHash(_ image: UIImage) -> String {
        // Convert to 8x8 grayscale grid for perceptual hashing
        let size = CGSize(width: 16, height: 16) // Increase to 16x16 for better accuracy
        
        UIGraphicsBeginImageContextWithOptions(size, true, 1.0)
        defer { UIGraphicsEndImageContext() }
        
        // Draw with white background to handle transparency
        let context = UIGraphicsGetCurrentContext()
        context?.setFillColor(UIColor.white.cgColor)
        context?.fill(CGRect(origin: .zero, size: size))
        
        // Draw the image centered and scaled to fill
        let drawRect = CGRect(origin: .zero, size: size)
        image.draw(in: drawRect, blendMode: .normal, alpha: 1.0)
        
        guard let resizedImage = UIGraphicsGetImageFromCurrentImageContext(),
              let cgImage = resizedImage.cgImage,
              let dataProvider = cgImage.dataProvider,
              let data = dataProvider.data,
              let bytes = CFDataGetBytePtr(data) else {
            return ""
        }
        
        // Convert to grayscale values
        var grayValues = [Int](repeating: 0, count: Int(size.width * size.height))
        var index = 0
        
        for y in 0..<Int(size.height) {
            for x in 0..<Int(size.width) {
                let pixelIndex = (y * Int(size.width) + x) * 4 // RGBA
                if pixelIndex < CFDataGetLength(data) - 3 {
                    let r = Int(bytes[pixelIndex])
                    let g = Int(bytes[pixelIndex + 1])
                    let b = Int(bytes[pixelIndex + 2])
                    // Use proper luminance formula for grayscale
                    let gray = Int(0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b))
                    grayValues[index] = gray
                    index += 1
                }
            }
        }
        
        // Calculate average brightness
        let average = grayValues.reduce(0, +) / grayValues.count
        
        // Create hash based on pixels above/below average
        var hash = ""
        for brightness in grayValues {
            hash += brightness > average ? "1" : "0"
        }
        
        return hash
    }
    
    private func hammingDistance(_ hash1: String, _ hash2: String) -> Int {
        guard hash1.count == hash2.count else { return Int.max }
        
        var distance = 0
        let chars1 = Array(hash1)
        let chars2 = Array(hash2)
        
        for i in 0..<chars1.count {
            if chars1[i] != chars2[i] {
                distance += 1
            }
        }
        
        return distance
    }
    
    func deleteAssets(_ assets: [PHAsset]) async throws {
        print("🗑️ Deleting \(assets.count) assets...")
        
        // Set a flag to indicate deletion in progress
        await MainActor.run {
            self.currentScanPhase = "Deleting \(assets.count) assets..."
        }
        
        // Find the duplicate groups that contain these assets
        let assetsToDeleteIds = Set(assets.map { $0.localIdentifier })
        let affectedGroups = duplicateGroups.filter { group in
            let groupAssetIds = Set(group.items.map { $0.assetIdentifier })
            return !groupAssetIds.isDisjoint(with: assetsToDeleteIds)
        }
        
        // For each affected group, merge metadata before deletion
        for group in affectedGroups {
            // Find the assets being kept and deleted in this group
            let keptItems = group.items.filter { !assetsToDeleteIds.contains($0.assetIdentifier) }
            let deletedItems = group.items.filter { assetsToDeleteIds.contains($0.assetIdentifier) }
            
            // Skip if no items are being kept (entire group deletion) or no items are being deleted
            if keptItems.isEmpty || deletedItems.isEmpty {
                continue
            }
            
            // For simplicity, we'll use the first kept item as the target for metadata merging
            if let keptItem = keptItems.first, let keptAsset = keptItem.asset {
                // Merge metadata from all deleted items to the kept item
                await mergeMetadata(from: deletedItems.compactMap { $0.asset }, to: keptAsset)
            }
        }
        
        // Perform the actual deletion
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
        }
        
        print("✅ Assets deleted successfully")
        
        // Refresh duplicate groups after deletion - with optimized version
        await refreshDuplicateGroups()
        
        // Force UI update
        await MainActor.run {
            self.objectWillChange.send()
            self.currentScanPhase = ""
        }
    }
    
    private func mergeMetadata(from sourceAssets: [PHAsset], to targetAsset: PHAsset) async {
        print("📝 Merging metadata from \(sourceAssets.count) assets to \(targetAsset.localIdentifier)")
        
        // Extract metadata from all assets
        var allMetadata: [ImageMetadata] = []
        
        // Get target asset's current metadata
        if let targetMetadata = extractMetadata(from: targetAsset) {
            allMetadata.append(targetMetadata)
        }
        
        // Get metadata from all source assets
        for asset in sourceAssets {
            if let metadata = extractMetadata(from: asset) {
                allMetadata.append(metadata)
            }
        }
        
        // Skip if we don't have enough metadata
        guard allMetadata.count > 1 else { return }
        
        // Merge metadata - we'll use PHAssetChangeRequest to modify the target asset
        do {
            try await PHPhotoLibrary.shared().performChanges {
                // Create a change request for the target asset
                let request = PHAssetChangeRequest(for: targetAsset)
                
                // Create merged metadata
                var mergedMetadata: [String: Any] = [:]
                
                // Merge location data if target doesn't have it but any source does
                if targetAsset.location == nil {
                    for asset in sourceAssets where asset.location != nil {
                        request.location = asset.location
                        break
                    }
                }
                
                // Merge creation date - keep the earliest one
                let allDates = [targetAsset] + sourceAssets
                if let earliestDate = allDates.compactMap({ $0.creationDate }).min() {
                    request.creationDate = earliestDate
                }
                
                // Note: Additional metadata like EXIF data would require more advanced handling
                // with PHContentEditingInput/Output, which is beyond the scope of this implementation
            }
            print("✅ Metadata merged successfully")
        } catch {
            print("❌ Error merging metadata: \(error)")
        }
    }
    
    func clearStoredResults() {
        storage.clearScanResults()
        duplicateGroups = []
        lastScanDate = nil
        totalAssetsScanned = 0
        newAssetsSinceLastScan = 0
        hasCompletedScan = false
        scanProgress = 0.0
        
        // Clear performance caches
        assetMetadataCache.removeAll()
        thumbnailHashCache.removeAll()
    }
    
    func getPerformanceStats() -> String {
        return "Cache: \(assetMetadataCache.count) metadata, \(thumbnailHashCache.count) hashes"
    }
    
    func getSpeedEstimate(for assetCount: Int) -> String {
        // Ultra-optimized algorithm: ~1000 assets per second for metadata grouping
        // ~200-500 assets per second for actual comparison
        let estimatedSeconds = max(assetCount / 500, 2) // At least 2 seconds minimum
        
        if estimatedSeconds < 60 {
            return "\(estimatedSeconds)s"
        } else {
            let minutes = estimatedSeconds / 60
            return "\(minutes)m \(estimatedSeconds % 60)s"
        }
    }
    
    func forceRefresh() async {
        await refreshDuplicateGroups()
        objectWillChange.send()
    }
    
    // Prefetch metadata for a batch of assets
    func prefetchMetadataForAssets(_ assets: [PHAsset]) {
        // Create a dispatch group to track completion
        let group = DispatchGroup()
        
        // Process assets in batches to avoid overloading the system
        let batchSize = 20
        for i in stride(from: 0, to: assets.count, by: batchSize) {
            let end = min(i + batchSize, assets.count)
            let batch = Array(assets[i..<end])
            
            for asset in batch {
                group.enter()
                
                // Request full metadata including original properties
                let assetKey = asset.localIdentifier as NSString
                
                // Skip if we already have this asset's metadata cached
                if metadataCache.object(forKey: assetKey) != nil {
                    group.leave()
                    continue
                }
                
                // Request resources in background
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    guard let self = self else { 
                        group.leave()
                        return 
                    }
                    
                    // Prefetch asset resources
                    _ = PHAssetResource.assetResources(for: asset)
                    
                    // Request metadata properties
                    PHAssetResource.assetResources(for: asset).forEach { resource in
                        PHAssetResourceManager.default().requestData(
                            for: resource,
                            options: nil,
                            dataReceivedHandler: { _ in
                                // Just triggering the load, we don't need the actual data
                            },
                            completionHandler: { _ in
                                // Resource data loaded
                            }
                        )
                    }
                    
                    // Request original metadata properties on main thread to avoid actor isolation issues
                    DispatchQueue.main.async {
                        let localAssetKey = assetKey // Capture in local variable to avoid warning
                        self.imageManager.requestImageDataAndOrientation(for: asset, options: self.metadataPrefetchOptions) { (_, _, _, info) in
                            // Store the metadata in our cache if available
                            if let metadata = info?["PHImageMetadataKey"] as? [String: Any] {
                                do {
                                    let data = try NSKeyedArchiver.archivedData(withRootObject: metadata, requiringSecureCoding: false)
                                    self.metadataCache.setObject(data as NSData, forKey: localAssetKey)
                                } catch {
                                    print("Error archiving metadata: \(error)")
                                }
                            }
                            group.leave()
                        }
                    }
                }
            }
        }
        
        // Optional: Wait for completion if needed
        group.notify(queue: .global(qos: .background)) {
            print("Metadata prefetching completed for \(assets.count) assets")
        }
    }
    
    // Call this method before displaying assets
    func prefetchAssetsData(_ assets: [PHAsset]) {
        // Prefetch metadata
        prefetchMetadataForAssets(assets)
        
        // Prefetch thumbnails
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        
        let targetSize = CGSize(width: 300, height: 300)
        
        // Request images for each asset to cache them
        for asset in assets {
            imageManager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options,
                resultHandler: { _, _ in
                    // The image will be cached by the system
                }
            )
        }
    }
    
    // Call this method before displaying duplicate items
    func prefetchDuplicateItemsData(_ items: [DuplicateItem]) {
        // Prefetch assets in background
        DispatchQueue.global(qos: .userInitiated).async {
            for item in items {
                item.prefetchAsset()
            }
        }
        
        // Prefetch metadata for any available assets
        let assets = items.compactMap { $0.asset }
        if !assets.isEmpty {
            prefetchAssetsData(assets)
        }
    }
    
    // Call when assets are no longer needed
    func stopPrefetchingAssetsData(_ assets: [PHAsset]) {
        // No explicit way to stop caching in PHImageManager
        // We'll just cancel any pending requests for these assets
        for asset in assets {
            let requestID = PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 300, height: 300),
                contentMode: .aspectFill,
                options: nil,
                resultHandler: { _, _ in }
            )
            
            PHImageManager.default().cancelImageRequest(requestID)
        }
    }
    
    private func extractMetadata(from asset: PHAsset) -> ImageMetadata? {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.isSynchronous = true
        options.deliveryMode = .highQualityFormat
        
        var metadata: ImageMetadata?
        
        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, orientation, info in
            guard let data = data else { return }
            
            // Create a CGImageSource from the image data
            if let imageSource = CGImageSourceCreateWithData(data as CFData, nil) {
                // Get the metadata dictionary
                if let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any] {
                    // Extract EXIF data
                    let exifData = properties["{Exif}"] as? [String: Any]
                    
                    // Extract GPS data
                    let gpsData = properties["{GPS}"] as? [String: Any]
                    
                    // Extract TIFF data (contains camera info)
                    let tiffData = properties["{TIFF}"] as? [String: Any]
                    
                    // Extract GPS coordinates
                    var latitude: Double?
                    var longitude: Double?
                    if let gpsData = gpsData,
                       let latitudeRef = gpsData["LatitudeRef"] as? String,
                       let latValue = gpsData["Latitude"] as? Double,
                       let longitudeRef = gpsData["LongitudeRef"] as? String,
                       let lonValue = gpsData["Longitude"] as? Double {
                        
                        let latSign = latitudeRef == "N" ? 1.0 : -1.0
                        let lonSign = longitudeRef == "E" ? 1.0 : -1.0
                        
                        latitude = latValue * latSign
                        longitude = lonValue * lonSign
                    }
                    
                    // Extract camera information
                    let cameraMake = tiffData?["Make"] as? String
                    let cameraModel = tiffData?["Model"] as? String
                    
                    // Extract ISO, aperture, shutter speed
                    let iso = exifData?["ISOSpeedRatings"] as? [NSNumber]
                    let aperture = exifData?["FNumber"] as? NSNumber
                    let shutterSpeed = exifData?["ExposureTime"] as? NSNumber
                    
                    // Get image dimensions
                    let width = asset.pixelWidth
                    let height = asset.pixelHeight
                    
                    // Create metadata object with all required parameters
                    metadata = ImageMetadata(
                        width: width,
                        height: height,
                        orientation: Int(orientation.rawValue),
                        cameraMake: cameraMake,
                        cameraModel: cameraModel,
                        iso: iso?.first?.doubleValue,
                        aperture: aperture?.doubleValue,
                        shutterSpeed: shutterSpeed?.doubleValue,
                        gpsLatitude: latitude,
                        gpsLongitude: longitude,
                        perceptualHash: nil // We'll compute this separately if needed
                    )
                }
            }
        }
        
        return metadata
    }
}

// MARK: - Array Extension for Batch Processing
extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
} 