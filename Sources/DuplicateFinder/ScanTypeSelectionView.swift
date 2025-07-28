import SwiftUI

public struct ScanTypeSelectionView: View {
    let newAssetsCount: Int
    let totalAssetsCount: Int
    @Binding var isPresented: Bool
    let onScanTypeSelected: (PhotoLibraryManager.ScanType) -> Void
    
    public init(newAssetsCount: Int, totalAssetsCount: Int, isPresented: Binding<Bool>, onScanTypeSelected: @escaping (PhotoLibraryManager.ScanType) -> Void) {
        self.newAssetsCount = newAssetsCount
        self.totalAssetsCount = totalAssetsCount
        self._isPresented = isPresented
        self.onScanTypeSelected = onScanTypeSelected
    }
    
    public var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                VStack(spacing: 16) {
                    Image(systemName: "magnifyingglass.circle.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.blue)
                    
                    Text("Choose Scan Type")
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    Text("Select how you want to scan for duplicates")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                
                VStack(spacing: 16) {
                    // Quick Scan Option
                    ScanOptionCard(
                        icon: "bolt.fill",
                        title: "Quick Scan",
                        subtitle: "Scan new photos only",
                        description: "Only scans \(newAssetsCount) photos added since your last scan. Faster but may miss some duplicates.",
                        estimatedTime: estimatedQuickScanTime(),
                        color: .orange,
                        isRecommended: newAssetsCount < totalAssetsCount / 2
                    ) {
                        onScanTypeSelected(.delta)
                        isPresented = false
                    }
                    
                    // Full Scan Option
                    ScanOptionCard(
                        icon: "magnifyingglass",
                        title: "Full Scan",
                        subtitle: "Scan entire library",
                        description: "Scans all \(totalAssetsCount) photos in your library. Takes longer but finds all duplicates.",
                        estimatedTime: estimatedFullScanTime(),
                        color: .blue,
                        isRecommended: newAssetsCount >= totalAssetsCount / 2
                    ) {
                        onScanTypeSelected(.full)
                        isPresented = false
                    }
                }
                
                Spacer()
                
                Button("Cancel") {
                    isPresented = false
                }
                .foregroundColor(.secondary)
            }
            .padding()
            .navigationTitle("Scan Options")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarHidden(true)
        }
    }
    
    private func estimatedQuickScanTime() -> String {
        if newAssetsCount < 100 {
            return "< 1 minute"
        } else if newAssetsCount < 1000 {
            return "1-3 minutes"
        } else {
            return "3-10 minutes"
        }
    }
    
    private func estimatedFullScanTime() -> String {
        if totalAssetsCount < 1000 {
            return "2-5 minutes"
        } else if totalAssetsCount < 5000 {
            return "5-15 minutes"
        } else {
            return "15+ minutes"
        }
    }
}

struct ScanOptionCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let description: String
    let estimatedTime: String
    let color: Color
    let isRecommended: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                HStack {
                    HStack(spacing: 12) {
                        Image(systemName: icon)
                            .font(.title2)
                            .foregroundColor(color)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(title)
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                
                                if isRecommended {
                                    Text("RECOMMENDED")
                                        .font(.caption2)
                                        .fontWeight(.bold)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.green)
                                        .foregroundColor(.white)
                                        .clipShape(Capsule())
                                }
                            }
                            
                            Text(subtitle)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Spacer()
                    
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(estimatedTime)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(color)
                        
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
            .background(color.opacity(0.1))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isRecommended ? Color.green : color.opacity(0.3), lineWidth: isRecommended ? 2 : 1)
            )
            .cornerRadius(12)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

#Preview {
    ScanTypeSelectionView(
        newAssetsCount: 45,
        totalAssetsCount: 2500,
        isPresented: .constant(true)
    ) { _ in }
} 
