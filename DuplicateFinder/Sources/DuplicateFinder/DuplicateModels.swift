import Foundation
import Photos
import SwiftUI
import CoreImage
import AVFoundation
import CryptoKit

// MARK: - Media Metadata Models

public struct ImageMetadata: Codable {
    let width: Int
    let height: Int
    let orientation: Int
    let cameraMake: String?
    let cameraModel: String?
    let iso: Double?
    let aperture: Double?
    let shutterSpeed: Double?
    let gpsLatitude: Double?
    let gpsLongitude: Double?
    let perceptualHash: ImageHash?
    
    var gpsCoordinates: CLLocationCoordinate2D? {
        guard let lat = gpsLatitude, let lon = gpsLongitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

public struct VideoMetadata: Codable {
    let width: Int
    let height: Int
    let duration: Double
    let frameRate: Float?
    let bitrate: Int64?
    let videoCodec: String?
    let audioCodec: String?
    let audioChannels: Int?
    let keyframeHashes: [ImageHash]?
}

// MARK: - Hashing and Fingerprinting

public struct ImageHash: Hashable, Codable {
    let pHash: UInt64    // Perceptual hash
    let dHash: UInt64    // Difference hash
    let aHash: UInt64    // Average hash
    
    func similarityScore(with other: ImageHash) -> Double {
        let pHashDiff = hammingDistance(pHash, other.pHash)
        let dHashDiff = hammingDistance(dHash, other.dHash)
        let aHashDiff = hammingDistance(aHash, other.aHash)
        
        // Weighted average of differences (lower is more similar)
        return (Double(pHashDiff) * 0.4 + Double(dHashDiff) * 0.4 + Double(aHashDiff) * 0.2) / 64.0
    }
    
    private func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        var xor = a ^ b
        var distance = 0
        while xor != 0 {
            distance += 1
            xor &= (xor - 1)
        }
        return distance
    }
}

public struct FileFingerprint: Hashable, Codable {
    let fileHash: String          // SHA256 hash of file content
    let fileSize: Int64          // File size in bytes
    let mediaType: AssetMediaType     // Type of media file
    let imageHash: ImageHash?    // For images and video keyframes
}

// MARK: - Enums

public enum AssetMediaType: Codable {
    case image
    case video
    case audio
    case unknown
}

public enum MediaType: String, Codable {
    case jpeg, png, heic, gif    // Image formats
    case mp4, mov, m4v          // Video formats
    
    var isVideo: Bool {
        switch self {
        case .mp4, .mov, .m4v: return true
        default: return false
        }
    }
}

public enum SimilarityType: String, CaseIterable, Codable {
    case exact = "Duplicates"
    case similar = "Similar Items"
    
    var description: String {
        switch self {
        case .exact:
            return "Identical content with same dimensions and metadata"
        case .similar:
            return "Visually similar content that may be variations"
        }
    }
    
    var icon: String {
        switch self {
        case .exact:
            return "doc.on.doc.fill"
        case .similar:
            return "rectangle.3.group.fill"
        }
    }
    
    var color: Color {
        switch self {
        case .exact:
            return .red
        case .similar:
            return .orange
        }
    }
}

public enum MediaTypeFilter: String, CaseIterable {
    case all = "All"
    case photos = "Photos"
    case videos = "Videos"
    
    var icon: String {
        switch self {
        case .all:
            return "square.stack.3d.up.fill"
        case .photos:
            return "photo.fill"
        case .videos:
            return "video.fill"
        }
    }
    
    var color: Color {
        switch self {
        case .all:
            return .blue
        case .photos:
            return .green
        case .videos:
            return .indigo
        }
    }
}

// MARK: - Core Models

public struct DuplicateGroup: Identifiable {
    public let id: String
    let items: [DuplicateItem]
    let similarityType: SimilarityType
    let matchConfidence: Double      // 0.0 to 1.0, higher means more confident match
    
    public init(items: [DuplicateItem], similarityType: SimilarityType = .similar, matchConfidence: Double = 1.0) {
        self.items = items
        self.similarityType = similarityType
        self.matchConfidence = matchConfidence
        // Create a stable ID based on the sorted asset identifiers
        let sortedIds = items.map { $0.assetIdentifier }.sorted()
        self.id = sortedIds.joined(separator: "_")
    }
    
    var totalSize: Int64 {
        items.reduce(0) { $0 + $1.fileSize }
    }
    
    var creationDates: [Date] {
        items.compactMap { $0.creationDate }.sorted()
    }
    
    var hasMultipleDates: Bool {
        let dates = creationDates
        guard dates.count > 1 else { return false }
        return dates.contains { abs($0.timeIntervalSince(dates.first!)) > 86400 }
    }
    
    // Check for mismatched properties across items in the group
    var mismatchedProperties: [String] {
        guard items.count > 1 else { return [] }
        
        var mismatches: [String] = []
        let firstItem = items[0]
        
        // Check for device mismatches
        let devices = Set(items.compactMap { $0.deviceModel })
        if devices.count > 1 {
            mismatches.append("Devices")
        }
        
        // Check for location mismatches (significant distance)
        if let firstLocation = firstItem.location {
            for item in items.dropFirst() {
                if let itemLocation = item.location {
                    let distance = firstLocation.distance(from: itemLocation)
                    if distance > 100 { // More than 100 meters
                        mismatches.append("Locations")
                        break
                    }
                } else {
                    // One has location, other doesn't
                    mismatches.append("Locations")
                    break
                }
            }
        } else if items.dropFirst().contains(where: { $0.location != nil }) {
            // First has no location but others do
            mismatches.append("Locations")
        }
        
        // Check for dimension mismatches
        let dimensions = Set(items.map { $0.dimensions })
        if dimensions.count > 1 {
            mismatches.append("Dimensions")
        }
        
        // Check for file size differences (>10% difference)
        let sizes = items.map { $0.fileSize }
        let maxSize = sizes.max() ?? 0
        let minSize = sizes.min() ?? 0
        if maxSize > 0 && Double(maxSize - minSize) / Double(maxSize) > 0.1 {
            mismatches.append("Sizes")
        }
        
        // Check for date differences (>1 hour)
        if let firstDate = firstItem.creationDate {
            for item in items.dropFirst() {
                if let itemDate = item.creationDate {
                    let timeDiff = abs(firstDate.timeIntervalSince(itemDate))
                    if timeDiff > 3600 { // More than 1 hour
                        mismatches.append("Dates")
                        break
                    }
                }
            }
        }
        
        return mismatches
    }
}

// Codable version of DuplicateGroup for persistence
struct StorableDuplicateGroup: Codable {
    let id: String
    let items: [StorableDuplicateItem]  // Use StorableDuplicateItem instead of DuplicateItem
    let similarityType: SimilarityType
    let matchConfidence: Double
    
    init(from group: DuplicateGroup) {
        self.id = group.id
        self.items = group.items.map { StorableDuplicateItem(from: $0) }
        self.similarityType = group.similarityType
        self.matchConfidence = group.matchConfidence
    }
    
    func toGroup() -> DuplicateGroup {
        return DuplicateGroup(
            items: items.map { $0.toItem() },
            similarityType: similarityType,
            matchConfidence: matchConfidence
        )
    }
}

public class DuplicateItem: Identifiable {
    public let id: UUID
    let assetIdentifier: String  // Store PHAsset identifier instead of PHAsset
    let fingerprint: FileFingerprint
    private let _fileSize: Int64
    
    // Cached metadata
    private(set) var imageMetadata: ImageMetadata?
    private(set) var videoMetadata: VideoMetadata?
    
    // Additional stored properties for persistence
    private let _dimensions: String
    private let _duration: Double?
    private let _creationDate: Date?
    private let _modificationDate: Date?
    private let _mediaType: Int // PHAssetMediaType raw value
    
    // Store location from asset during initialization to avoid fetching on demand
    private var _cachedLocation: CLLocation?
    
    // Cache for PHAsset to avoid fetching on demand
    private static var assetCache = [String: PHAsset]()
    private static let assetCacheQueue = DispatchQueue(label: "com.duplicategallery.assetCache", attributes: .concurrent)
    
    public init(asset: PHAsset, fingerprint: FileFingerprint) {
        self.id = UUID()
        self.assetIdentifier = asset.localIdentifier
        self.fingerprint = fingerprint
        
        // Store asset properties
        self._dimensions = "\(asset.pixelWidth) × \(asset.pixelHeight)"
        self._duration = asset.mediaType == .video ? asset.duration : nil
        self._creationDate = asset.creationDate
        self._modificationDate = asset.modificationDate
        self._mediaType = asset.mediaType.rawValue
        
        // Cache the location
        self._cachedLocation = asset.location
        
        // Calculate file size
        if let resource = PHAssetResource.assetResources(for: asset).first {
            self._fileSize = resource.value(forKey: "fileSize") as? Int64 ?? 0
        } else {
            self._fileSize = 0
        }
        
        // Cache the asset for future use
        DuplicateItem.assetCacheQueue.async(flags: .barrier) {
            DuplicateItem.assetCache[asset.localIdentifier] = asset
        }
        
        // Initialize metadata with basic information
        if asset.mediaType == .image {
            self.imageMetadata = ImageMetadata(
                width: asset.pixelWidth,
                height: asset.pixelHeight,
                orientation: 1, // Default orientation
                cameraMake: nil,
                cameraModel: asset.creationDate?.timeIntervalSince1970 ?? 0 > 1577836800 ? "iPhone" : nil, // Default to iPhone for photos after 2020
                iso: nil,
                aperture: nil,
                shutterSpeed: nil,
                gpsLatitude: asset.location?.coordinate.latitude,
                gpsLongitude: asset.location?.coordinate.longitude,
                perceptualHash: nil
            )
        }
    }
    
    // Add a designated initializer to support the convenience initializer in the extension
    init(
        id: UUID,
        assetIdentifier: String,
        fingerprint: FileFingerprint,
        fileSize: Int64,
        dimensions: String,
        duration: Double?,
        creationDate: Date?,
        modificationDate: Date?,
        mediaType: Int,
        imageMetadata: ImageMetadata?,
        videoMetadata: VideoMetadata?,
        locationLatitude: Double?,
        locationLongitude: Double?
    ) {
        self.id = id
        self.assetIdentifier = assetIdentifier
        self.fingerprint = fingerprint
        self._fileSize = fileSize
        self._dimensions = dimensions
        self._duration = duration
        self._creationDate = creationDate
        self._modificationDate = modificationDate
        self._mediaType = mediaType
        self.imageMetadata = imageMetadata
        self.videoMetadata = videoMetadata
        
        // Create location from coordinates if available
        if let lat = locationLatitude, let lon = locationLongitude {
            self._cachedLocation = CLLocation(latitude: lat, longitude: lon)
        }
    }
    
    // MARK: - Computed Properties
    
    var asset: PHAsset? {
        // First check the cache
        var cachedAsset: PHAsset?
        DuplicateItem.assetCacheQueue.sync {
            cachedAsset = DuplicateItem.assetCache[assetIdentifier]
        }
        
        if let cachedAsset = cachedAsset {
            return cachedAsset
        }
        
        // If not in cache, fetch on a background queue and cache the result
        let options = PHFetchOptions()
        options.fetchLimit = 1
        
        // Create a semaphore to make this synchronous but not block the main thread
        let semaphore = DispatchSemaphore(value: 0)
        var fetchedAsset: PHAsset?
        
        DispatchQueue.global(qos: .userInitiated).async {
            let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [self.assetIdentifier], options: options)
            fetchedAsset = fetchResult.firstObject
            
            // Cache the result if found
            if let asset = fetchedAsset {
                DuplicateItem.assetCacheQueue.async(flags: .barrier) {
                    DuplicateItem.assetCache[self.assetIdentifier] = asset
                }
            }
            
            semaphore.signal()
        }
        
        // If we're on the main thread, don't wait - return nil and let the UI update when asset is fetched
        if Thread.isMainThread {
            // Fetch in background and update UI later if needed
            return nil
        } else {
            // If not on main thread, we can wait for the result
            _ = semaphore.wait(timeout: .now() + 0.5) // Timeout after 0.5 seconds
            return fetchedAsset
        }
    }
    
    // Method to prefetch asset - call this from a background queue
    func prefetchAsset() {
        // Check if already cached
        var isCached = false
        DuplicateItem.assetCacheQueue.sync {
            isCached = DuplicateItem.assetCache[assetIdentifier] != nil
        }
        
        if isCached { 
            // Even if the asset is cached, we should still prefetch location
            prefetchLocation()
            return 
        }
        
        // Fetch and cache the asset
        let options = PHFetchOptions()
        options.fetchLimit = 1
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: options)
        
        if let asset = fetchResult.firstObject {
            DuplicateItem.assetCacheQueue.async(flags: .barrier) {
                DuplicateItem.assetCache[self.assetIdentifier] = asset
            }
            
            // Also cache the location
            if let assetLocation = asset.location {
                _cachedLocation = assetLocation
            }
        }
    }
    
    var fileSize: Int64 { _fileSize }
    
    var creationDate: Date? { _creationDate }
    
    var modificationDate: Date? { _modificationDate }
    
    var location: CLLocation? {
        // First check if we have location data in imageMetadata
        if let lat = imageMetadata?.gpsLatitude, let lon = imageMetadata?.gpsLongitude {
            return CLLocation(latitude: lat, longitude: lon)
        }
        
        // Then check if we have cached the location
        if let cachedLocation = _cachedLocation {
            return cachedLocation
        }
        
        // As a last resort, try to get it from the asset but not on main thread
        if !Thread.isMainThread, let assetLocation = asset?.location {
            // We can't modify self here, so just return the location without caching
            return assetLocation
        }
        
        return nil
    }
    
    // Method to prefetch and cache location - call this from a background queue
    func prefetchLocation() {
        // Skip if we already have location data
        if _cachedLocation != nil || (imageMetadata?.gpsLatitude != nil && imageMetadata?.gpsLongitude != nil) {
            return
        }
        
        // Get location from asset and cache it
        if let assetLocation = asset?.location {
            _cachedLocation = assetLocation
        }
    }
    
    var mediaType: PHAssetMediaType { PHAssetMediaType(rawValue: _mediaType) ?? .unknown }
    
    var dimensions: String { _dimensions }
    
    // Accessor for _duration
    var durationValue: Double? { _duration }
    
    var duration: String? {
        guard let duration = _duration else { return nil }
        let minutes = Int(duration / 60)
        let seconds = Int(duration.truncatingRemainder(dividingBy: 60))
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    // Device information
    var deviceModel: String? {
        return imageMetadata?.cameraModel ?? "Unknown Device"
    }
    
    // Location information formatted for display
    var locationDisplay: String? {
        guard let location = location else { 
            return imageMetadata?.gpsCoordinates != nil ? 
                   String(format: "%.6f, %.6f", imageMetadata!.gpsCoordinates!.latitude, imageMetadata!.gpsCoordinates!.longitude) : 
                   nil
        }
        return String(format: "%.6f, %.6f", location.coordinate.latitude, location.coordinate.longitude)
    }
    
    // MARK: - Metadata Formatting
    
    var formattedMetadata: [String: String] {
        var metadata: [String: String] = [
            "Dimensions": dimensions,
            "File Size": ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
        ]
        
        if let date = creationDate {
            metadata["Created"] = DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
        }
        
        // Add device information
        if let make = imageMetadata?.cameraMake, !make.isEmpty {
            metadata["Camera Make"] = make
        }
        
        if let model = imageMetadata?.cameraModel, !model.isEmpty {
            metadata["Camera Model"] = model
        } else if let model = deviceModel, model != "Unknown Device" {
            metadata["Device"] = model
        }
        
        // Add location information
        if let location = location {
            metadata["Location"] = String(format: "%.6f, %.6f", 
                location.coordinate.latitude, 
                location.coordinate.longitude)
        } else if let coords = imageMetadata?.gpsCoordinates {
            metadata["Location"] = String(format: "%.6f, %.6f", coords.latitude, coords.longitude)
        }
        
        // Add image-specific metadata
        if let imgMeta = imageMetadata {
            if let iso = imgMeta.iso { metadata["ISO"] = String(format: "%.0f", iso) }
            if let aperture = imgMeta.aperture { metadata["Aperture"] = String(format: "f/%.1f", aperture) }
        }
        
        // Add video-specific metadata
        if let videoMeta = videoMetadata {
            metadata["Duration"] = duration ?? "Unknown"
            if let frameRate = videoMeta.frameRate {
                metadata["Frame Rate"] = String(format: "%.2f fps", frameRate)
            }
            if let bitrate = videoMeta.bitrate {
                metadata["Bitrate"] = ByteCountFormatter.string(fromByteCount: bitrate / 8, countStyle: .binary) + "/s"
            }
            if let videoCodec = videoMeta.videoCodec { metadata["Video Codec"] = videoCodec }
            if let audioCodec = videoMeta.audioCodec { metadata["Audio Codec"] = audioCodec }
            if let channels = videoMeta.audioChannels { metadata["Audio Channels"] = "\(channels)" }
        }
        
        return metadata
    }
}

// MARK: - Codable version of DuplicateItem for persistence
struct StorableDuplicateItem: Codable {
    let id: UUID
    let assetIdentifier: String
    let fingerprint: FileFingerprint
    let fileSize: Int64
    let dimensions: String
    let duration: Double?
    let creationDate: Date?
    let modificationDate: Date?
    let mediaType: Int
    let imageMetadata: ImageMetadata?
    let videoMetadata: VideoMetadata?
    // Store location coordinates separately to avoid PHAsset dependency
    let locationLatitude: Double?
    let locationLongitude: Double?
    
    init(from item: DuplicateItem) {
        self.id = item.id
        self.assetIdentifier = item.assetIdentifier
        self.fingerprint = item.fingerprint
        self.fileSize = item.fileSize
        self.dimensions = item.dimensions
        self.duration = item.durationValue
        self.creationDate = item.creationDate
        self.modificationDate = item.modificationDate
        self.mediaType = item.mediaType.rawValue
        self.imageMetadata = item.imageMetadata
        self.videoMetadata = item.videoMetadata
        
        // Store location coordinates
        if let location = item.location {
            self.locationLatitude = location.coordinate.latitude
            self.locationLongitude = location.coordinate.longitude
        } else {
            self.locationLatitude = nil
            self.locationLongitude = nil
        }
    }
    
    func toItem() -> DuplicateItem {
        // Fetch the asset using the stored identifier
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: nil)
        if let asset = fetchResult.firstObject {
            return DuplicateItem(asset: asset, fingerprint: fingerprint)
        } else {
            // Use the storable initializer if the asset doesn't exist anymore
            return DuplicateItem(storable: self)
        }
    }
}

// MARK: - Filtering

struct DuplicateFilter {
    var mediaType: MediaTypeFilter = .all
    var similarityType: SimilarityType? = nil
    var minFileSize: Int64? = nil
    var maxFileSize: Int64? = nil
    var dateRange: ClosedRange<Date>? = nil
    var minConfidence: Double = 0.8  // Minimum similarity confidence (0.0 to 1.0)
    
    func shouldInclude(_ group: DuplicateGroup) -> Bool {
        // Check similarity type and confidence
        if let similarityType = similarityType, 
           group.similarityType != similarityType || group.matchConfidence < minConfidence {
            return false
        }
        
        // Check media type
        if mediaType != .all {
            let firstAsset = group.items.first?.asset
            let isPhoto = firstAsset?.mediaType == .image
            if mediaType == .photos && !isPhoto { return false }
            if mediaType == .videos && isPhoto { return false }
        }
        
        // Check file size
        let totalSize = group.totalSize
        if let minSize = minFileSize, totalSize < minSize { return false }
        if let maxSize = maxFileSize, totalSize > maxSize { return false }
        
        // Check date range
        if let range = dateRange,
           let firstDate = group.creationDates.first,
           !range.contains(firstDate) {
            return false
        }
        
        return true
    }
}

// MARK: - Extensions

extension DateFormatter {
    static let shared: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
    
    static func formattedDate(_ date: Date) -> String {
        return shared.string(from: date)
    }
    
    static var scanDate: DateFormatter {
        shared
    }
    
    static var shortDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter
    }()
    
    static var longDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter
    }()
    
    static var time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}

// Extension to DuplicateItem for initializing from StorableDuplicateItem
extension DuplicateItem {
    convenience init(storable: StorableDuplicateItem) {
        // Initialize with required properties
        self.init(
            id: storable.id,
            assetIdentifier: storable.assetIdentifier,
            fingerprint: storable.fingerprint,
            fileSize: storable.fileSize,
            dimensions: storable.dimensions,
            duration: storable.duration,
            creationDate: storable.creationDate,
            modificationDate: storable.modificationDate,
            mediaType: storable.mediaType,
            imageMetadata: storable.imageMetadata,
            videoMetadata: storable.videoMetadata,
            locationLatitude: storable.locationLatitude,
            locationLongitude: storable.locationLongitude
        )
    }
}
