import MudOutputView_macOS
import MudUI
import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 0) {
            MudOutputView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            StatusBarView(state: .disconnected)
        }
    }
}
