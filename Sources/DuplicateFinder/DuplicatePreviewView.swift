import SwiftUI
import Photos
import AVKit

public struct DuplicatePreviewView: View {
    let group: DuplicateGroup
    let photoManager: PhotoLibraryManager
    @Binding var selectedItems: Set<UUID>
    let initialIndex: Int
    
    @Environment(\.presentationMode) var presentationMode
    @State private var currentIndex: Int
    @State private var isShowingControls = true
    @State private var isShowingDeleteAlert = false
    
    public init(group: DuplicateGroup, photoManager: PhotoLibraryManager, selectedItems: Binding<Set<UUID>>, initialIndex: Int) {
        self.group = group
        self.photoManager = photoManager
        self._selectedItems = selectedItems
        self.initialIndex = initialIndex
        self._currentIndex = State(initialValue: initialIndex)
    }
    
    public var body: some View {
        ZStack {
            // Black background
            Color.black.edgesIgnoringSafeArea(.all)
            
            // Media preview
            TabView(selection: $currentIndex) {
                ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                    MediaPreviewView(item: item, photoManager: photoManager)
                        .tag(index)
                        .onAppear {
                            // Prefetch metadata when this item becomes visible
                            if let asset = item.asset {
                                photoManager.prefetchMetadataForAssets([asset])
                            }
                        }
                        .onDisappear {
                            // Stop caching when item is no longer visible
                            if let asset = item.asset {
                                photoManager.stopPrefetchingAssetsData([asset])
                            }
                        }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .onTapGesture {
                withAnimation {
                    isShowingControls.toggle()
                }
            }
            
            // Controls overlay
            if isShowingControls {
                VStack {
                    // Top controls
                    HStack {
                        Button(action: {
                            presentationMode.wrappedValue.dismiss()
                        }) {
                            Image(systemName: "xmark")
                                .font(.title3)
                                .foregroundColor(.white)
                                .padding()
                                .background(Color.black.opacity(0.5))
                                .clipShape(Circle())
                        }
                        
                        Spacer()
                        
                        // Selection button
                        let currentItem = group.items[currentIndex]
                        let isSelected = selectedItems.contains(currentItem.id)
                        
                        Button(action: {
                            if isSelected {
                                selectedItems.remove(currentItem.id)
                            } else {
                                selectedItems.insert(currentItem.id)
                            }
                        }) {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.title2)
                                .foregroundColor(isSelected ? .red : .white)
                                .padding()
                                .background(Color.black.opacity(0.5))
                                .clipShape(Circle())
                        }
                        
                        Button(action: {
                            isShowingDeleteAlert = true
                        }) {
                            Image(systemName: "trash")
                                .font(.title3)
                                .foregroundColor(.white)
                                .padding()
                                .background(Color.black.opacity(0.5))
                                .clipShape(Circle())
                        }
                    }
                    .padding()
                    
                    Spacer()
                    
                    // Info overlay
                    if let item = group.items[safe: currentIndex] {
                        MediaInfoOverlay(item: item)
                            .padding()
                    }
                }
                .transition(.opacity)
            }
        }
        .alert("Delete This Item", isPresented: $isShowingDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                Task {
                    await deleteCurrentItem()
                }
            }
        } message: {
            Text("This will permanently delete this item. This action cannot be undone.")
        }
        .onAppear {
            // Prefetch metadata for nearby items to improve performance
            prefetchNearbyItems()
        }
    }
    
    private func prefetchNearbyItems() {
        // Get a range of items to prefetch (current + 2 before and after)
        let startIdx = max(0, currentIndex - 2)
        let endIdx = min(group.items.count - 1, currentIndex + 2)
        
        let itemsToPrefetch = Array(group.items[startIdx...endIdx])
        let assets = itemsToPrefetch.compactMap { $0.asset }
        
        // Prefetch metadata and thumbnails
        photoManager.prefetchAssetsData(assets)
    }
    
    private func deleteCurrentItem() async {
        guard currentIndex < group.items.count else { return }
        
        let item = group.items[currentIndex]
        guard let asset = item.asset else { return }
        
        do {
            try await photoManager.deleteAssets([asset])
            
            // If we've deleted all items, dismiss the view
            if group.items.count <= 1 {
                presentationMode.wrappedValue.dismiss()
            }
        } catch {
            print("Error deleting asset: \(error)")
        }
    }
}

struct MediaPreviewView: View {
    let item: DuplicateItem
    let photoManager: PhotoLibraryManager
    @State private var image: UIImage?
    @State private var isLoading = true
    @State private var player: AVPlayer?
    
    var body: some View {
        ZStack {
            if isLoading {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(1.5)
            }
            
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .onAppear {
                        isLoading = false
                    }
            } else if let player = player {
                VideoPlayer(player: player)
                    .onAppear {
                        isLoading = false
                        player.play()
                    }
                    .onDisappear {
                        player.pause()
                    }
            }
        }
        .onAppear {
            loadMedia()
        }
    }
    
    private func loadMedia() {
        guard let asset = item.asset else { return }
        
        if asset.mediaType == .image {
            loadImage(asset: asset)
        } else if asset.mediaType == .video {
            loadVideo(asset: asset)
        }
    }
    
    private func loadImage(asset: PHAsset) {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        options.progressHandler = { _, _, _, _ in
            // Could update a progress indicator here
        }
        
        // Use screen size as target size for better quality
        let targetSize = UIScreen.main.bounds.size
        
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFit,
            options: options
        ) { result, info in
            if let image = result {
                DispatchQueue.main.async {
                    self.image = image
                    self.isLoading = false
                }
            }
        }
    }
    
    private func loadVideo(asset: PHAsset) {
        let options = PHVideoRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        
        PHImageManager.default().requestAVAsset(
            forVideo: asset,
            options: options
        ) { avAsset, _, _ in
            if let avAsset = avAsset {
                DispatchQueue.main.async {
                    self.player = AVPlayer(playerItem: AVPlayerItem(asset: avAsset))
                    self.isLoading = false
                }
            }
        }
    }
}

struct MediaInfoOverlay: View {
    let item: DuplicateItem
    
    private func formatFileSize(_ size: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: size)
    }
    
    private func formatDateTime(_ date: Date) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        return dateFormatter.string(from: date)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Date and time
            if let creationDate = item.creationDate {
                HStack {
                    Image(systemName: "calendar")
                    Text(formatDateTime(creationDate))
                }
            }
            
            // Dimensions
            HStack {
                Image(systemName: "aspectratio")
                Text(item.dimensions)
            }
            
            // File size
            HStack {
                Image(systemName: "internaldrive")
                Text(formatFileSize(item.fileSize))
            }
            
            // Device model
            if let deviceModel = item.deviceModel {
                HStack {
                    Image(systemName: "camera")
                    Text(deviceModel)
                }
            }
            
            // Location
            if let location = item.location {
                HStack {
                    Image(systemName: "location")
                    Text(String(format: "%.4f, %.4f", location.coordinate.latitude, location.coordinate.longitude))
                }
            }
        }
        .font(.caption)
        .foregroundColor(.white)
        .padding()
        .background(Color.black.opacity(0.7))
        .cornerRadius(10)
    }
}

extension Collection {
    /// Returns the element at the specified index if it is within bounds, otherwise nil.
    subscript (safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
} 
