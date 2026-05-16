import MudCore
import MudOutputView_macOS
import MudUI
import SwiftUI

struct ContentView: View {
    let store: ScrollbackStore

    var body: some View {
        VStack(spacing: 0) {
            MudOutputView(store: store)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            StatusBarView(state: .disconnected)
        }
    }
}
