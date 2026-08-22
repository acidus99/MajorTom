import MajorTomCore
import SwiftUI

struct ICloudTabsView: View {
    @ObservedObject private var cloud = ICloudSyncStore.shared

    var body: some View {
        Group {
            if cloud.remoteTabDevices.isEmpty {
                ContentUnavailableView(
                    "No Tabs From Other Macs",
                    systemImage: "icloud",
                    description: Text(emptyDescription)
                )
            } else {
                List {
                    ForEach(cloud.remoteTabDevices) { device in
                        Section {
                            ForEach(device.tabs) { tab in
                                Button {
                                    NotificationCenter.default.post(
                                        name: .majorTomOpenICloudTab,
                                        object: tab.url
                                    )
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(tab.title).lineLimit(1)
                                        Text(tab.url.absoluteString)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        } header: {
                            HStack {
                                Label(device.deviceName, systemImage: "desktopcomputer")
                                Spacer()
                                Text(device.updatedAt, style: .relative)
                                    .textCase(nil)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("iCloud Tabs")
        .toolbar {
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") { cloud.refresh() }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Image(systemName: statusSymbol)
                Text(cloud.status.label)
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .task { cloud.refresh() }
    }

    private var emptyDescription: String {
        switch cloud.status {
        case .unavailable, .failed:
            cloud.status.label
        default:
            "Open tabs on another Mac signed in to the same iCloud account will appear here."
        }
    }

    private var statusSymbol: String {
        switch cloud.status {
        case .preparing, .syncing: "arrow.trianglehead.2.clockwise.rotate.90.icloud"
        case .upToDate: "checkmark.icloud"
        case .unavailable, .failed: "exclamationmark.icloud"
        }
    }
}
