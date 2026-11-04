import StowExtensionSDK
import SwiftUI

struct AccessoryViews: View {
    let store: AppStore
    var noteID: UUID?
    var body: some View {
        ForEach(store.state.extensionInstances.filter { $0.isEnabled && $0.noteID == noteID }) { instance in
            HStack(spacing: 6) {
                if let result = store.accessoryResults[instance.id], let snapshot = result.snapshot {
                    if let symbol = snapshot.systemImage { Image(systemName: symbol) }
                    Text(snapshot.primaryText).lineLimit(1)
                    if result.isCached { Image(systemName: "clock").help("Cached accessory") }
                } else {
                    Image(systemName: "puzzlepiece.extension")
                    Text(store.accessoryResults[instance.id]?.error?.message ?? "Loading accessory…").lineLimit(2)
                }
                Spacer(minLength: 0)
            }.font(.system(size: 10)).foregroundStyle(.stowMuted).padding(.horizontal, 12).padding(.bottom, 9)
        }
    }
}
