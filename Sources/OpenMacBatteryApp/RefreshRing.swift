import SwiftUI

struct RefreshRingButton: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Button {
            model.refreshLiveWatts()
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .padding(2)
        }
        .buttonStyle(.plain)
        .help("Refresh live wattage")
    }
}
