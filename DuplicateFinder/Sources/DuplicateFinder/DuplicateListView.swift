import SwiftUI
import Photos

public enum SortOption: String, CaseIterable {
    case dateNewest = "Date (Newest)"
    case dateOldest = "Date (Oldest)"
    case sizeSmallest = "Size (Smallest)"
    case sizeLargest = "Size (Largest)"
    
    var icon: String {
        switch self {
        case .dateNewest: return "arrow.up.circle"
        case .dateOldest: return "arrow.down.circle"
        case .sizeSmallest: return "arrow.up.circle"
        case .sizeLargest: return "arrow.down.circle"
        }
    }
}

public struct DuplicateListView: View {
    @ObservedObject var photoManager: PhotoLibraryManager
    
    // Persist filter and sort settings using AppStorage
    @AppStorage("mediaTypeFilter") private var mediaTypeFilterRawValue = MediaTypeFilter.all.rawValue
    @AppStorage("similarityTypeFilter") private var similarityTypeFilterRawValue: String?
    @AppStorage("sortOption") private var sortOptionRawValue = SortOption.dateNewest.rawValue
    
    @State private var showingDeleteAlert = false
    @State private var selectedGroup: DuplicateGroup?
    @State private var showingSuccessToast = false
    @State private var successMessage = ""
    @State private var showingSortMenu = false
    @State private var isCalculatingSize = false
    
    // Environment values to detect device size and orientation
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    
    public init(photoManager: PhotoLibraryManager) {
        self.photoManager = photoManager
    }
    
    // Computed properties to convert between raw values and actual types
    private var mediaTypeFilter: MediaTypeFilter {
        get { MediaTypeFilter(rawValue: mediaTypeFilterRawValue) ?? .all }
        set { mediaTypeFilterRawValue = newValue.rawValue }
    }
    
    private var similarityTypeFilter: SimilarityType? {
        get { 
            guard let rawValue = similarityTypeFilterRawValue else { return nil }
            return SimilarityType(rawValue: rawValue)
        }
        set { similarityTypeFilterRawValue = newValue?.rawValue }
    }
    
    private var sortOption: SortOption {
        get { SortOption(rawValue: sortOptionRawValue) ?? .dateNewest }
        set { sortOptionRawValue = newValue.rawValue }
    }
    
    // Create filter from persisted values
    private var filter: DuplicateFilter {
        get {
            var filter = DuplicateFilter()
            filter.mediaType = mediaTypeFilter
            filter.similarityType = similarityTypeFilter
            return filter
        }
        set {
            mediaTypeFilter = newValue.mediaType
            similarityTypeFilter = newValue.similarityType
        }
    }
    
    // Adaptive column layout based on device size and orientation
    private var columns: [GridItem] {
        // Determine number of columns based on size class
        let columnCount: Int
        
        if horizontalSizeClass == .regular && verticalSizeClass == .regular {
            // iPad in any orientation
            columnCount = 5
        } else if horizontalSizeClass == .regular && verticalSizeClass == .compact {
            // iPhone in landscape or iPad in split view
            columnCount = 4
        } else {
            // iPhone in portrait
            columnCount = 2
        }
        
        return Array(repeating: GridItem(.flexible(), spacing: 16), count: columnCount)
    }
    
    private var filteredGroups: [DuplicateGroup] {
        let filtered = photoManager.duplicateGroups.filter { filter.shouldInclude($0) }
        
        return filtered.sorted { group1, group2 in
            switch sortOption {
            case .dateNewest:
                return (group1.items.first?.creationDate ?? .distantPast) > (group2.items.first?.creationDate ?? .distantPast)
            case .dateOldest:
                return (group1.items.first?.creationDate ?? .distantPast) < (group2.items.first?.creationDate ?? .distantPast)
            case .sizeSmallest:
                return group1.totalSize < group2.totalSize
            case .sizeLargest:
                return group1.totalSize > group2.totalSize
            }
        }
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Filter section
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    // Media type filters
                    ForEach(MediaTypeFilter.allCases, id: \.rawValue) { type in
                        FilterChip(
                            title: type.rawValue,
                            icon: type.icon,
                            isSelected: mediaTypeFilter == type,
                            color: type.color
                        ) {
                            withAnimation {
                                mediaTypeFilterRawValue = type.rawValue
                            }
                        }
                    }
                    
                    Divider()
                        .frame(height: 24)
                    
                    // Similarity type filters
                    ForEach(SimilarityType.allCases, id: \.rawValue) { type in
                        FilterChip(
                            title: type.rawValue,
                            icon: type.icon,
                            isSelected: similarityTypeFilter == type,
                            color: type.color
                        ) {
                            withAnimation {
                                similarityTypeFilterRawValue = similarityTypeFilter == type ? nil : type.rawValue
                            }
                        }
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            
            // Grid view
            if filteredGroups.isEmpty {
                // Empty state
                VStack(spacing: 20) {
                    Image(systemName: "photo.stack")
                        .font(.system(size: 60))
                        .foregroundColor(.secondary)
                    
                    Text("No Matches Found")
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    Text("Try adjusting your filters to see more results")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemGroupedBackground))
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(filteredGroups) { group in
                            NavigationLink(destination: DuplicateDetailView(group: group, photoManager: photoManager)) {
                                DuplicateGridCell(group: group, photoManager: photoManager)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .onAppear {
                                // Prefetch data for items in this group when it appears in view
                                photoManager.prefetchDuplicateItemsData(group.items)
                            }
                        }
                    }
                    .padding(16)
                }
                .overlay {
                    if isCalculatingSize {
                        ProgressView("Calculating sizes...")
                            .padding()
                            .background(Color(.systemBackground).opacity(0.8))
                            .cornerRadius(10)
                    }
                }
            }
        }
        .navigationTitle("Duplicate Groups")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if !photoManager.duplicateGroups.isEmpty {
                    Menu {
                        ForEach(SortOption.allCases, id: \.rawValue) { option in
                            Button(action: {
                                withAnimation {
                                    sortOptionRawValue = option.rawValue
                                }
                            }) {
                                HStack {
                                    Text(option.rawValue)
                                    if sortOption == option {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down.circle")
                            .foregroundColor(.blue)
                    }
                    
                    Button("Refresh") {
                        Task {
                            await photoManager.forceRefresh()
                        }
                    }
                    
                    Button("Delete All") {
                        showingDeleteAlert = true
                    }
                    .foregroundColor(.red)
                }
            }
        }
        .alert("Delete All Duplicates", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                Task {
                    await deleteAllDuplicates()
                }
            }
        } message: {
            Text("This will delete all duplicate photos and videos, keeping only the best version of each. This action cannot be undone.")
        }
        .overlay(alignment: .top) {
            if showingSuccessToast {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.white)
                    Text(successMessage)
                        .foregroundColor(.white)
                        .font(.subheadline)
                }
                .padding()
                .background(Color.green)
                .cornerRadius(10)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        withAnimation {
                            showingSuccessToast = false
                        }
                    }
                }
            }
        }
    }
    
    private func deleteAllDuplicates() async {
        var totalDeleted = 0
        let groupCount = photoManager.duplicateGroups.count
        
        await MainActor.run {
            successMessage = "Processing duplicate groups..."
            withAnimation {
                showingSuccessToast = true
            }
        }
        
        for group in photoManager.duplicateGroups {
            // Keep the best item and delete the rest
            // Select the best item based on file size, quality, and creation date
            let bestItem = selectBestItemInGroup(group)
            
            // All items except the best one will be deleted
            let itemsToDelete = group.items.filter { $0.id != bestItem.id }
            let assetsToDelete = itemsToDelete.compactMap { $0.asset }
            
            do {
                // The deleteAssets method now handles metadata merging
                try await photoManager.deleteAssets(assetsToDelete)
                totalDeleted += itemsToDelete.count
            } catch {
                print("Error deleting assets: \(error)")
            }
        }
        
        await MainActor.run {
            successMessage = "Cleaned up \(groupCount) duplicate groups, deleted \(totalDeleted) items"
            withAnimation {
                showingSuccessToast = true
            }
        }
    }
    
    private func selectBestItemInGroup(_ group: DuplicateGroup) -> DuplicateItem {
        guard !group.items.isEmpty else { return group.items[0] }
        
        // Logic to select the best item based on:
        // 1. File size (larger is usually better)
        // 2. Modification date (more recent modifications)
        // 3. Creation date (keep the original)
        
        return group.items.max { item1, item2 in
            // Prioritize by file size first
            let sizeThreshold = max(item1.fileSize, item2.fileSize) / 10 // 10% threshold as Int64
            if abs(item1.fileSize - item2.fileSize) > sizeThreshold {
                return item1.fileSize < item2.fileSize
            }
            
            // If file sizes are similar, prefer the one with more metadata
            let meta1Count = item1.formattedMetadata.count
            let meta2Count = item2.formattedMetadata.count
            if meta1Count != meta2Count {
                return meta1Count < meta2Count
            }
            
            // Then by creation date (keep original)
            let date1 = item1.creationDate ?? Date.distantPast
            let date2 = item2.creationDate ?? Date.distantPast
            return date1 > date2
        } ?? group.items[0]
    }
}

struct FilterChip: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let color: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                Text(title)
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? color.opacity(0.2) : Color(.systemGray6))
            .foregroundColor(isSelected ? color : .primary)
            .cornerRadius(20)
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(isSelected ? color : Color.clear, lineWidth: 1)
            )
        }
    }
}

struct DuplicateGridCell: View {
    let group: DuplicateGroup
    let photoManager: PhotoLibraryManager
    @State private var thumbnail: UIImage?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Thumbnail
            ZStack {
                GeometryReader { geometry in
                    if let thumbnail = thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geometry.size.width, height: geometry.size.width)
                            .clipped()
                    } else {
                        Rectangle()
                            .fill(Color(.systemGray5))
                            .overlay(
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle())
                            )
                    }
                    
                    // Overlay badges
                    VStack {
                        HStack {
                            Spacer()
                            Text("\(group.items.count)")
                                .font(.caption)
                                .padding(6)
                                .background(Color.black.opacity(0.7))
                                .foregroundColor(.white)
                                .cornerRadius(12)
                        }
                        
                        Spacer()
                        
                        HStack {
                            // Media type badge
                            if let firstAsset = group.items.first?.asset {
                                Image(systemName: firstAsset.mediaType == .video ? "video.fill" : "photo.fill")
                                    .foregroundColor(.white)
                                    .padding(6)
                                    .background(Color.black.opacity(0.7))
                                    .cornerRadius(12)
                            }
                            
                            Spacer()
                            
                            // Similarity type badge
                            Image(systemName: group.similarityType.icon)
                                .foregroundColor(group.similarityType.color)
                                .padding(6)
                                .background(Color.black.opacity(0.7))
                                .cornerRadius(12)
                        }
                    }
                    .padding(8)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .cornerRadius(12)
            
            // Info
            VStack(alignment: .leading, spacing: 4) {
                if let firstDate = group.items.first?.creationDate {
                    Text(DateFormatter.formattedDate(firstDate))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                // Add device info if available
                if let firstItem = group.items.first, let cameraModel = firstItem.imageMetadata?.cameraModel {
                    Text(cameraModel)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                // Add location if available
                if let firstItem = group.items.first, let location = firstItem.location {
                    HStack {
                        Image(systemName: "location.fill")
                            .font(.caption2)
                        Text(formatLocation(location.coordinate))
                            .font(.caption)
                    }
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                }
                
                // Display mismatched properties
                let mismatches = group.mismatchedProperties
                if !mismatches.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(mismatches, id: \.self) { mismatch in
                                MismatchBadge(text: mismatch)
                            }
                        }
                    }
                    .frame(height: 22)
                }
                
                if group.hasMultipleDates {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Multiple dates")
                            .foregroundColor(.orange)
                    }
                    .font(.caption)
                }
            }
            .padding(.horizontal, 4)
        }
        .onAppear {
            loadThumbnail()
        }
        .onDisappear {
            // Stop caching when cell disappears from view
            if let asset = group.items.first?.asset {
                photoManager.stopPrefetchingAssetsData([asset])
            }
        }
    }
    
    private func formatLocation(_ coordinate: CLLocationCoordinate2D) -> String {
        return String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude)
    }
    
    private func loadThumbnail() {
        guard let firstAsset = group.items.first?.asset else { return }
        
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false // Ensure async loading
        
        let targetSize = CGSize(width: 400, height: 400) // Higher resolution for better quality
        PHImageManager.default().requestImage(
            for: firstAsset,
            targetSize: targetSize,
            contentMode: .aspectFit,
            options: options
        ) { image, _ in
            if let image = image {
                DispatchQueue.main.async {
                    self.thumbnail = image
                }
            }
        }
    }
}

struct MismatchBadge: View {
    let text: String
    
    var body: some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.purple.opacity(0.2))
            .foregroundColor(.purple)
            .cornerRadius(4)
    }
} 
