import SwiftUI

public struct LaunchScreenView: View {
    @State private var size = 0.8
    @State private var opacity = 0.5
    
    public init() {}
    
    public var body: some View {
        ZStack {
            Color("launch-background")
                .edgesIgnoringSafeArea(.all)
            
            VStack {
                Image("LaunchImage")
                    .resizable()
                    .scaledToFit()
                    .padding(.all, 32)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .scaleEffect(size)
                    .opacity(opacity)
            }
        }
        .onAppear {
            withAnimation(.easeIn(duration: 1.2)) {
                self.size = 0.9
                self.opacity = 1.0
            }
        }
    }
}

#Preview {
    LaunchScreenView()
} 
