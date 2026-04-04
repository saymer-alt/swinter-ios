import SwiftUI
import SystemConfiguration.CaptiveNetwork
import NetworkExtension

struct ScenesView: View {
    @EnvironmentObject var vpn: VPNManager
    @State private var showAddScene = false
    @State private var editingScene: VPNScene?
    @State private var currentSSID: String = "—"

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("SCENES")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(.white.opacity(0.35))
                Spacer()

                // Current SSID indicator
                HStack(spacing: 4) {
                    Image(systemName: "wifi")
                        .font(.system(size: 10))
                    Text(currentSSID)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.4))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.white.opacity(0.06), in: Capsule())

                Button { showAddScene = true } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Color(red: 0.0, green: 0.85, blue: 1.0))
                }
            }
            .padding(.horizontal, 4)

            if vpn.appConfig.scenes.isEmpty {
                Text("Нет сцен. Сцены автоматически переключают VPN по WiFi сети или типу подключения.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.3))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            } else {
                ForEach(vpn.appConfig.scenes) { scene in
                    SceneRow(scene: scene, servers: vpn.appConfig.servers, groups: vpn.appConfig.groups) {
                        editingScene = scene
                    } onToggle: { enabled in
                        vpn.toggleScene(scene.id, enabled: enabled)
                    }
                }
            }
        }
        .onAppear { fetchSSID() }
        .sheet(isPresented: $showAddScene) {
            SceneEditView(scene: nil) { vpn.addScene($0) }
        }
        .sheet(item: $editingScene) { scene in
            SceneEditView(scene: scene) { vpn.updateScene($0) }
        }
    }

    private func fetchSSID() {
        // iOS 14+ requires NEHotspotHelper or CNCopyCurrentNetworkInfo entitlement
        if let interfaces = CNCopySupportedInterfaces() as? [String],
           let first = interfaces.first,
           let info = CNCopyCurrentNetworkInfo(first as CFString) as? [String: Any],
           let ssid = info[kCNNetworkInfoKeySSID as String] as? String {
            currentSSID = ssid
        } else {
            currentSSID = "N/A"
        }
    }
}

// MARK: - Scene Row

struct SceneRow: View {
    let scene: VPNScene
    let servers: [Server]
    let groups: [ProxyGroup]
    let onEdit: () -> Void
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Enable toggle
            Toggle("", isOn: Binding(
                get: { scene.enabled },
                set: { onToggle($0) }
            ))
            .labelsHidden()
            .tint(Color(red: 0.0, green: 0.85, blue: 1.0))

            VStack(alignment: .leading, spacing: 3) {
                Text(scene.name.isEmpty ? "Unnamed Scene" : scene.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(scene.enabled ? 0.9 : 0.4))

                HStack(spacing: 6) {
                    // Conditions summary
                    ForEach(scene.conditions, id: \.value) { cond in
                        HStack(spacing: 2) {
                            Image(systemName: conditionIcon(cond.type))
                                .font(.system(size: 9))
                            Text(cond.value)
                                .font(.system(size: 10))
                        }
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.white.opacity(0.06), in: Capsule())
                    }

                    // Action
                    Text("→ \(actionLabel)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color(red: 0.0, green: 0.85, blue: 1.0).opacity(0.7))
                }
            }

            Spacer()

            Button { onEdit() } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.06), lineWidth: 0.5))
    }

    private var actionLabel: String {
        switch scene.action.type {
        case .connect: return "Connect"
        case .disconnect: return "Disconnect"
        case .switchServer:
            if let id = scene.action.targetID, let s = servers.first(where: { $0.id == id }) {
                return s.name.isEmpty ? s.address : s.name
            }
            return "Switch Server"
        case .switchGroup:
            if let id = scene.action.targetID, let g = groups.first(where: { $0.id == id }) {
                return g.name
            }
            return "Switch Group"
        }
    }

    private func conditionIcon(_ type: SceneConditionType) -> String {
        switch type {
        case .ssid: return "wifi"
        case .networkType: return "antenna.radiowaves.left.and.right"
        case .timeRange: return "clock"
        }
    }
}

// MARK: - Scene Edit

struct SceneEditView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var vpn: VPNManager

    let initialScene: VPNScene?
    let onSave: (VPNScene) -> Void

    @State private var name: String
    @State private var conditionType: SceneConditionType
    @State private var conditionValue: String
    @State private var actionType: SceneActionType
    @State private var targetID: UUID?

    init(scene: VPNScene?, onSave: @escaping (VPNScene) -> Void) {
        self.initialScene = scene
        self.onSave = onSave
        let s = scene ?? VPNScene()
        _name = State(initialValue: s.name)
        _conditionType = State(initialValue: s.conditions.first?.type ?? .ssid)
        _conditionValue = State(initialValue: s.conditions.first?.value ?? "")
        _actionType = State(initialValue: s.action.type)
        _targetID = State(initialValue: s.action.targetID)
    }

    var body: some View {
        NavigationView {
            Form {
                Section("Scene") {
                    TextField("Name (e.g. Home WiFi)", text: $name)
                }

                Section("When") {
                    Picker("Condition", selection: $conditionType) {
                        Text("WiFi SSID").tag(SceneConditionType.ssid)
                        Text("Network Type").tag(SceneConditionType.networkType)
                        Text("Time Range").tag(SceneConditionType.timeRange)
                    }

                    switch conditionType {
                    case .ssid:
                        TextField("SSID name", text: $conditionValue)
                            .autocapitalization(.none)
                    case .networkType:
                        Picker("Type", selection: $conditionValue) {
                            Text("WiFi").tag("wifi")
                            Text("Cellular").tag("cellular")
                        }
                    case .timeRange:
                        TextField("Range (e.g. 09:00-18:00)", text: $conditionValue)
                    }
                }

                Section("Then") {
                    Picker("Action", selection: $actionType) {
                        Text("Connect VPN").tag(SceneActionType.connect)
                        Text("Disconnect VPN").tag(SceneActionType.disconnect)
                        Text("Switch Server").tag(SceneActionType.switchServer)
                        Text("Switch Group").tag(SceneActionType.switchGroup)
                    }

                    if actionType == .switchServer && !vpn.appConfig.servers.isEmpty {
                        Picker("Server", selection: $targetID) {
                            Text("None").tag(nil as UUID?)
                            ForEach(vpn.appConfig.servers) { s in
                                Text(s.name.isEmpty ? s.address : s.name).tag(s.id as UUID?)
                            }
                        }
                    }

                    if actionType == .switchGroup && !vpn.appConfig.groups.isEmpty {
                        Picker("Group", selection: $targetID) {
                            Text("None").tag(nil as UUID?)
                            ForEach(vpn.appConfig.groups) { g in
                                Text(g.name).tag(g.id as UUID?)
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(red: 0.04, green: 0.05, blue: 0.1))
            .navigationTitle(initialScene == nil ? "New Scene" : "Edit Scene")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        var scene = initialScene ?? VPNScene()
                        scene.name = name
                        scene.conditions = [SceneCondition(type: conditionType, value: conditionValue)]
                        scene.action = SceneAction(type: actionType, targetID: targetID)
                        onSave(scene)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}
