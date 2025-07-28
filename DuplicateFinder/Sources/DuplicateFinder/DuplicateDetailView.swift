import SwiftUI
import Photos
import Combine

public struct DuplicateDetailView: View {
    let group: DuplicateGroup
    @ObservedObject var photoManager: PhotoLibraryManager
    @State private var selectedItems: Set<UUID> = []
    @State private var showingDatePicker = false
    @State private var selectedDate: Date?
    @State private var showingDeleteAlert = false
    @State private var showingSuccessToast = false
    @State private var successMessage = ""
    @State private var currentGroup: DuplicateGroup
    @State private var showingPreview = false
    @State private var previewStartIndex = 0
    @Environment(\.presentationMode) var presentationMode
    
    // Environment values to detect device size and orientation
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    
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
    
    public init(group: DuplicateGroup, photoManager: PhotoLibraryManager) {
        self.group = group
        self.photoManager = photoManager
        self._currentGroup = State(initialValue: group)
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Date selection section if needed
            if currentGroup.hasMultipleDates {
                DateSelectionCard(
                    dates: currentGroup.creationDates,
                    selectedDate: $selectedDate,
                    showingDatePicker: $showingDatePicker
                )
                .padding()
            }
            
            // Grid of duplicate items
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(Array(currentGroup.items.enumerated()), id: \.element.id) { index, item in
                        DuplicateGridItemCard(
                            item: item,
                            isSelected: selectedItems.contains(item.id),
                            onSelectionChanged: { isSelected in
                                if isSelected {
                                    selectedItems.insert(item.id)
                                } else {
                                    selectedItems.remove(item.id)
                                }
                            },
                            onTapPreview: {
                                previewStartIndex = index
                                showingPreview = true
                            },
                            group: currentGroup,
                            photoManager: photoManager
                        )
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("Duplicate Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                // Preview button
                Button(action: {
                    previewStartIndex = 0
                    showingPreview = true
                }) {
                    Image(systemName: "photo.stack.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.blue)
                }
                
                // Select best button
                Button(action: {
                    selectBestItem()
                }) {
                    Image(systemName: "star.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.yellow)
                }
                
                // Delete button
                Button(action: {
                    showingDeleteAlert = true
                }) {
                    Image(systemName: "trash.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.red)
                }
                .disabled(selectedItems.isEmpty)
            }
        }
        .alert("Delete Selected Items", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                Task {
                    await deleteSelectedItems()
                }
            }
        } message: {
            Text("This will permanently delete the selected items. This action cannot be undone.")
        }
        .sheet(isPresented: $showingDatePicker) {
            DatePickerView(
                dates: currentGroup.creationDates,
                selectedDate: $selectedDate,
                isPresented: $showingDatePicker
            )
        }
        .fullScreenCover(isPresented: $showingPreview) {
            DuplicatePreviewView(
                group: currentGroup,
                photoManager: photoManager,
                selectedItems: $selectedItems,
                initialIndex: previewStartIndex
            )
        }
        .onReceive(photoManager.$duplicateGroups) { updatedGroups in
            if let updatedGroup = updatedGroups.first(where: { $0.id == group.id }) {
                currentGroup = updatedGroup
                selectedItems = selectedItems.filter { selectedId in
                    currentGroup.items.contains { $0.id == selectedId }
                }
            } else {
                presentationMode.wrappedValue.dismiss()
            }
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
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation {
                            showingSuccessToast = false
                        }
                    }
                }
            }
        }
        .onAppear {
            // Prefetch metadata for all assets in the group when view appears
            photoManager.prefetchDuplicateItemsData(currentGroup.items)
        }
    }
    
    private func selectBestItem() {
        selectedItems.removeAll()
        
        guard !currentGroup.items.isEmpty else { return }
        
        // Logic to select the best item based on:
        // 1. Selected date preference
        // 2. File size (larger is usually better)
        // 3. Metadata richness (more metadata is better)
        // 4. Creation date (keep the original)
        
        var bestItem: DuplicateItem = currentGroup.items[0]
        
        if let preferredDate = selectedDate {
            // Find item closest to preferred date
            if let closestItem = currentGroup.items.min(by: { item1, item2 in
                let date1 = item1.creationDate ?? Date.distantPast
                let date2 = item2.creationDate ?? Date.distantPast
                return abs(date1.timeIntervalSince(preferredDate)) < abs(date2.timeIntervalSince(preferredDate))
            }) {
                bestItem = closestItem
            }
        } else {
            // Select based on file size, metadata richness, and dates
            bestItem = currentGroup.items.max { item1, item2 in
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
            } ?? currentGroup.items[0]
        }
        
        // Select all items except the best one for deletion
        for item in currentGroup.items {
            if item.id != bestItem.id {
                selectedItems.insert(item.id)
            }
        }
    }
    
    private func deleteSelectedItems() async {
        let itemsToDelete = currentGroup.items.filter { selectedItems.contains($0.id) }
        let assetsToDelete = itemsToDelete.compactMap { $0.asset }
        
        guard !itemsToDelete.isEmpty else { return }
        
        // Add loading state
        await MainActor.run {
            successMessage = "Merging metadata and deleting \(itemsToDelete.count) item(s)..."
            withAnimation {
                showingSuccessToast = true
            }
        }
        
        do {
            // Perform deletion with metadata merging
            try await photoManager.deleteAssets(assetsToDelete)
            
            // Update UI immediately
            await MainActor.run {
                selectedItems.removeAll()
                successMessage = "Deleted \(itemsToDelete.count) duplicate\(itemsToDelete.count == 1 ? "" : "s") with metadata preserved"
            }
            
            // Check if we need to dismiss the view
            let shouldDismiss = itemsToDelete.count >= currentGroup.items.count - 1
            
            if shouldDismiss {
                // If we deleted all but one item (or all items), dismiss after a delay
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                await MainActor.run {
                    presentationMode.wrappedValue.dismiss()
                }
            }
        } catch {
            print("Error deleting selected items: \(error)")
            await MainActor.run {
                successMessage = "Error deleting items: \(error.localizedDescription)"
                withAnimation {
                    showingSuccessToast = true
                }
            }
        }
    }
}

struct DateSelectionCard: View {
    let dates: [Date]
    @Binding var selectedDate: Date?
    @Binding var showingDatePicker: Bool
    
    private func formatDateTime(_ date: Date) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        return dateFormatter.string(from: date)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Multiple Creation Dates Found")
                .font(.headline)
                .foregroundColor(.orange)
            
            Text("These duplicates have different creation dates. Select which date to prioritize:")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Button(action: {
                showingDatePicker = true
            }) {
                HStack {
                    Text(selectedDate.map { formatDateTime($0) } ?? "Select Date & Time")
                    Spacer()
                    Image(systemName: "chevron.right")
                }
                .padding()
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)
            }
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(12)
    }
}

struct DuplicateGridItemCard: View {
    let item: DuplicateItem
    let isSelected: Bool
    let onSelectionChanged: (Bool) -> Void
    let onTapPreview: () -> Void
    let group: DuplicateGroup
    let photoManager: PhotoLibraryManager
    
    @State private var thumbnail: UIImage?
    
    private func formatFileSize(_ size: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: size)
    }
    
    private func formatLocation(_ coordinate: CLLocationCoordinate2D) -> String {
        return String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude)
    }
    
    private func formatDateTime(_ date: Date) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .short
        dateFormatter.timeStyle = .short
        return dateFormatter.string(from: date)
    }
    
    // Check if this item has properties that differ from the first item in the group
    private var mismatchedProperties: [String] {
        guard let firstItem = group.items.first, firstItem.id != item.id else { return [] }
        
        var mismatches: [String] = []
        
        // Check device mismatch
        if let firstDevice = firstItem.deviceModel, 
           let thisDevice = item.deviceModel,
           firstDevice != thisDevice {
            mismatches.append("Device")
        }
        
        // Check location mismatch
        if let firstLocation = firstItem.location, let thisLocation = item.location {
            let distance = firstLocation.distance(from: thisLocation)
            if distance > 100 { // More than 100 meters
                mismatches.append("Location")
            }
        } else if (firstItem.location == nil && item.location != nil) || 
                  (firstItem.location != nil && item.location == nil) {
            mismatches.append("Location")
        }
        
        // Check dimensions mismatch
        if firstItem.dimensions != item.dimensions {
            mismatches.append("Size")
        }
        
        // Check file size mismatch (>10% difference)
        let sizeDiff = abs(Double(firstItem.fileSize - item.fileSize)) / Double(max(firstItem.fileSize, item.fileSize))
        if sizeDiff > 0.1 {
            mismatches.append("File Size")
        }
        
        // Check date mismatch (>1 hour)
        if let firstDate = firstItem.creationDate, let thisDate = item.creationDate {
            let timeDiff = abs(firstDate.timeIntervalSince(thisDate))
            if timeDiff > 3600 { // More than 1 hour
                mismatches.append("Date")
            }
        }
        
        return mismatches
    }
    
    var body: some View {
        Button(action: onTapPreview) {
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
                        
                        // Selection overlay
                        if isSelected {
                            Color.red.opacity(0.3)
                        }
                        
                        // Media type indicator and file size
                        VStack {
                            HStack {
                                // File size badge
                                Text(formatFileSize(item.fileSize))
                                    .font(.caption2)
                                    .foregroundColor(.white)
                                    .padding(6)
                                    .background(Color.black.opacity(0.7))
                                    .cornerRadius(12)
                                
                                Spacer()
                                
                                // Media type badge
                                Image(systemName: item.mediaType == .video ? "video.fill" : "photo.fill")
                                    .foregroundColor(.white)
                                    .padding(6)
                                    .background(Color.black.opacity(0.7))
                                    .cornerRadius(12)
                            }
                            
                            Spacer()
                        }
                        .padding(8)
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(isSelected ? Color.red : Color.clear, lineWidth: 2)
                )
                
                // Info
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        if let creationDate = item.creationDate {
                            Text(formatDateTime(creationDate))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        // File size with color indicator
                        Text(formatFileSize(item.fileSize))
                            .font(.caption)
                            .foregroundColor(item.fileSize > 10_000_000 ? .orange : .secondary) // Orange if > 10MB
                    }
                    
                    HStack {
                        Text(item.dimensions)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        if let duration = item.duration {
                            Text("•")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(duration)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    // Add device info if available
                    if let cameraModel = item.imageMetadata?.cameraModel {
                        Text(cameraModel)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    
                    // Add location if available
                    if let location = item.location {
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
                    let mismatches = mismatchedProperties
                    if !mismatches.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                ForEach(mismatches, id: \.self) { mismatch in
                                    DetailMismatchBadge(text: mismatch)
                                }
                            }
                        }
                        .frame(height: 22)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .overlay(alignment: .bottomTrailing) {
            // Selection button
            Button(action: {
                onSelectionChanged(!isSelected)
            }) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundColor(isSelected ? .red : .white)
                    .padding(6)
                    .background(Color.black.opacity(0.7))
                    .clipShape(Circle())
            }
            .padding(8)
            .padding(.bottom, 40)
        }
        .onAppear {
            loadThumbnail()
            
            // Prefetch asset and metadata in background
            DispatchQueue.global(qos: .userInitiated).async {
                item.prefetchAsset()
                if let asset = item.asset {
                    DispatchQueue.main.async {
                        photoManager.prefetchMetadataForAssets([asset])
                    }
                }
            }
        }
        .onDisappear {
            // Stop caching when cell disappears
            if let asset = item.asset {
                photoManager.stopPrefetchingAssetsData([asset])
            }
        }
    }
    
    private func loadThumbnail() {
        guard let asset = item.asset else { return }
        
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        
        // Add these options to prevent main thread metadata fetching
        options.isSynchronous = false
        
        let targetSize = CGSize(width: 400, height: 400)
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        ) { image, info in
            if let image = image {
                DispatchQueue.main.async {
                    self.thumbnail = image
                }
            } else if let info = info, info[PHImageErrorKey] != nil {
                // If we failed to load without network, try again with network allowed
                options.isNetworkAccessAllowed = true
                PHImageManager.default().requestImage(
                    for: asset,
                    targetSize: targetSize,
                    contentMode: .aspectFill,
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
    }
}

struct DetailMismatchBadge: View {
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

struct DatePickerView: View {
    let dates: [Date]
    @Binding var selectedDate: Date?
    @Binding var isPresented: Bool
    
    private func formatDate(_ date: Date) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .none
        return dateFormatter.string(from: date)
    }
    
    private func formatTime(_ date: Date) -> String {
        let timeFormatter = DateFormatter()
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .medium
        return timeFormatter.string(from: date)
    }
    
    var body: some View {
        NavigationView {
            List {
                ForEach(dates, id: \.self) { date in
                    Button(action: {
                        selectedDate = date
                        isPresented = false
                    }) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(formatDate(date))
                                    .font(.headline)
                                Text(formatTime(date))
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            if selectedDate == date {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                        .foregroundColor(.primary)
                    }
                }
            }
            .navigationTitle("Select Date & Time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        isPresented = false
                    }
                }
            }
        }
    }
} 
