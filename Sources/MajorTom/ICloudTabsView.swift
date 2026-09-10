import AppKit
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
                                    openInNewTab(tab.url)
                                } label: {
                                    HStack(alignment: .top, spacing: 8) {
                                        Group {
                                            if let favicon = tab.favicon {
                                                Text(favicon)
                                            } else {
                                                Image(systemName: "info.circle")
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        .frame(width: 20, height: 20)
                                        .accessibilityHidden(true)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(tab.title).lineLimit(1)
                                            Text(tab.url.absoluteString)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Open in New Tab", systemImage: BrowserMenuIcon.newTab) {
                                        openInNewTab(tab.url)
                                    }
                                    Button("Open in New Window", systemImage: BrowserMenuIcon.newWindow) {
                                        NativeTabCoordinator.shared.openWindow(url: tab.url)
                                    }
                                    Divider()
                                    Button("Copy URL", systemImage: BrowserMenuIcon.copyLink) {
                                        copyURL(tab.url)
                                    }
                                }
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
                Button("Refresh", systemImage: "arrow.clockwise") {
                    NativeTabCoordinator.shared.publishCloudTabsIfNeeded()
                    cloud.refresh()
                }
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
        .task {
            NativeTabCoordinator.shared.publishCloudTabsIfNeeded()
            cloud.refresh()
        }
    }

    private var emptyDescription: String {
        switch cloud.status {
        case .unavailable, .removed, .requiresNewerApp, .failed:
            cloud.status.label
        default:
            "Open tabs on another Mac signed in to the same iCloud account will appear here."
        }
    }

    private func openInNewTab(_ url: URL) {
        NotificationCenter.default.post(name: .majorTomOpenICloudTab, object: url)
    }

    private func copyURL(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    private var statusSymbol: String {
        switch cloud.status {
        case .preparing, .syncing: "arrow.trianglehead.2.clockwise.rotate.90.icloud"
        case .upToDate: "checkmark.icloud"
        case .unavailable, .removed, .requiresNewerApp, .failed: "exclamationmark.icloud"
        }
    }
}
