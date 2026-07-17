import SwiftUI
import VibeBuddyCore

// Device pairing list, pushed from the 设置 tab.
//
// Discovery scanning is bound to this view's lifetime (onAppear /
// onDisappear) rather than the app's: it scans with allowDuplicates so
// the RSSI readings stay live, which costs radio time we don't want to
// spend while the user is just dictating.
struct DevicePairingView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var ble: BLEController

    private var connectedID: String? {
        guard case .connected(let name) = state.link else { return nil }
        return BLEController.deviceID(fromName: name)
    }

    private var unpaired: [AppState.DiscoveredDevice] {
        state.discoveredDevices.filter { !state.pairedDeviceIDs.contains($0.id) }
    }

    var body: some View {
        Form {
            Section {
                if state.pairedDeviceIDs.isEmpty {
                    Text("（无）").foregroundStyle(.secondary)
                } else {
                    ForEach(state.pairedDeviceIDs, id: \.self) { id in
                        HStack {
                            Circle()
                                .fill(connectedID == id ? Color.green : Color.secondary.opacity(0.4))
                                .frame(width: 8, height: 8)
                            Text("VibeBuddy-\(id)")
                                .font(.system(.body, design: .monospaced))
                            if connectedID == id {
                                Text("已连接").font(.caption).foregroundStyle(.green)
                            }
                            Spacer()
                            Button("取消配对", role: .destructive) {
                                ble.unpair(deviceID: id)
                            }
                            .buttonStyle(.borderless)
                            .font(.callout)
                        }
                    }
                }
            } header: {
                Text("已配对")
            } footer: {
                Text(state.pairedDeviceIDs.isEmpty
                     ? "未配对时会连接第一个搜索到的 VibeBuddy 设备。配对后只连白名单内的设备。"
                     : "只有列表中的设备会被自动连接。设备 ID 是机身屏幕上显示的四位十六进制。")
            }

            Section {
                if unpaired.isEmpty {
                    HStack {
                        Text(state.discovering ? "搜索中…" : "未搜索到未配对的设备")
                            .foregroundStyle(.secondary)
                        Spacer()
                        if state.discovering { ProgressView() }
                    }
                } else {
                    ForEach(unpaired) { dev in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(dev.name).font(.system(.body, design: .monospaced))
                                Text("\(dev.rssi) dBm").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("配对") { ble.pair(deviceID: dev.id) }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            } header: {
                Text("附近设备")
            }
        }
        .navigationTitle("设备")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { ble.startDiscovery() }
        .onDisappear { ble.stopDiscovery() }
    }
}
