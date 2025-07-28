import Foundation
import Photos

public struct StoredScanResult: Codable {
    let scanDate: Date
    let duplicateGroups: [StoredDuplicateGroup]
    let totalAssetsScanned: Int
    let lastAssetDate: Date?
    
    struct StoredDuplicateGroup: Codable, Identifiable {
        let id: String
        let items: [StoredDuplicateItem]
        let similarityType: String // Store as string for compatibility
        
        func toDuplicateGroup() -> DuplicateGroup? {
            let duplicateItems = items.compactMap { $0.toDuplicateItem() }
            guard duplicateItems.count > 1 else { return nil }
            
            // Convert stored similarity type back to enum
            let type = SimilarityType(rawValue: similarityType) ?? .similar
            return DuplicateGroup(items: duplicateItems, similarityType: type)
        }
    }
    
    struct StoredDuplicateItem: Codable, Identifiable {
        let id: String
        let assetIdentifier: String
        let creationDate: Date?
        let modificationDate: Date?
        let mediaType: Int // PHAssetMediaType raw value
        let pixelWidth: Int
        let pixelHeight: Int
        let duration: TimeInterval
        
        func toDuplicateItem() -> DuplicateItem? {
            let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: nil)
            
            if let asset = fetchResult.firstObject {
                // Convert PHAssetMediaType to your custom MediaType
                let assetMediaType = mapPHAssetMediaType(asset.mediaType)
                
                // Create a default fingerprint
                let fingerprint = FileFingerprint(
                    fileHash: "",
                    fileSize: 0,
                    mediaType: assetMediaType,
                    imageHash: nil
                )
                
                return DuplicateItem(asset: asset, fingerprint: fingerprint)
            }
            
            return nil
        }
        
        func mapPHAssetMediaType(_ type: PHAssetMediaType) -> AssetMediaType {
            switch type {
                case .image:
                    return .image
                case .video:
                    return .video
                case .audio:
                    return .audio
                default:
                    return .unknown
            }
        }
    }
}

public class ScanResultStorage: ObservableObject {
    private let storageKey = "DuplicateFinderScanResults"
    
    func saveScanResults(_ duplicateGroups: [DuplicateGroup], totalAssetsScanned: Int, lastAssetDate: Date?) {
        let storedGroups = duplicateGroups.map { group in
            let storedItems = group.items.compactMap { item -> StoredScanResult.StoredDuplicateItem? in
                guard let asset = item.asset else { return nil }
                
                return StoredScanResult.StoredDuplicateItem(
                    id: item.id.uuidString,
                    assetIdentifier: asset.localIdentifier,
                    creationDate: asset.creationDate,
                    modificationDate: asset.modificationDate,
                    mediaType: asset.mediaType.rawValue,
                    pixelWidth: asset.pixelWidth,
                    pixelHeight: asset.pixelHeight,
                    duration: asset.duration
                )
            }
            return StoredScanResult.StoredDuplicateGroup(
                id: group.id,
                items: storedItems,
                similarityType: group.similarityType.rawValue
            )
        }
        
        let scanResult = StoredScanResult(
            scanDate: Date(),
            duplicateGroups: storedGroups,
            totalAssetsScanned: totalAssetsScanned,
            lastAssetDate: lastAssetDate
        )
        
        if let encoded = try? JSONEncoder().encode(scanResult) {
            UserDefaults.standard.set(encoded, forKey: storageKey)
            print("✅ Saved scan results: \(duplicateGroups.count) groups, \(totalAssetsScanned) assets scanned")
        }
    }
    
    func loadScanResults() -> (duplicateGroups: [DuplicateGroup], scanDate: Date?, totalAssetsScanned: Int, lastAssetDate: Date?)? {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let scanResult = try? JSONDecoder().decode(StoredScanResult.self, from: data) else {
            return nil
        }
        
        let duplicateGroups = scanResult.duplicateGroups.compactMap { $0.toDuplicateGroup() }
        
        print("📱 Loaded scan results: \(duplicateGroups.count) groups from \(scanResult.scanDate)")
        return (
            duplicateGroups: duplicateGroups,
            scanDate: scanResult.scanDate,
            totalAssetsScanned: scanResult.totalAssetsScanned,
            lastAssetDate: scanResult.lastAssetDate
        )
    }
    
    func clearScanResults() {
        UserDefaults.standard.removeObject(forKey: storageKey)
        print("🗑️ Cleared stored scan results")
    }
    
    func hasSavedResults() -> Bool {
        return UserDefaults.standard.data(forKey: storageKey) != nil
    }
    
    func getScanDate() -> Date? {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let scanResult = try? JSONDecoder().decode(StoredScanResult.self, from: data) else {
            return nil
        }
        return scanResult.scanDate
    }
} 
