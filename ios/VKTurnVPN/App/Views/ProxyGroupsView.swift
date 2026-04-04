import SwiftUI

struct ProxyGroupsView: View {
    @EnvironmentObject var vpn: VPNManager
    @State private var showAddGroup = false
    @State private var editingGroup: ProxyGroup?

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("PROXY GROUPS")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(.white.opacity(0.35))
                Spacer()
                Button { showAddGroup = true } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Color(red: 0.0, green: 0.85, blue: 1.0))
                }
            }
            .padding(.horizontal, 4)

            if vpn.appConfig.groups.isEmpty {
                Text("Нет групп. Группы позволяют автоматически выбирать сервер по скорости или доступности.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.3))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            } else {
                ForEach(vpn.appConfig.groups) { group in
                    GroupRow(group: group, servers: vpn.appConfig.servers) {
                        editingGroup = group
                    }
                }
            }
        }
        .sheet(isPresented: $showAddGroup) {
            GroupEditView(group: nil) { vpn.addGroup($0) }
        }
        .sheet(item: $editingGroup) { group in
            GroupEditView(group: group) { vpn.updateGroup($0) }
        }
    }
}

struct GroupRow: View {
    let group: ProxyGroup
    let servers: [Server]
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: groupIcon)
                .font(.system(size: 16))
                .foregroundStyle(groupColor)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(group.name.isEmpty ? "Unnamed Group" : group.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))

                HStack(spacing: 6) {
                    Text(group.type.displayName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                    Text("\(memberCount) серверов")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.3))
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

    private var memberCount: Int {
        group.serverIDs.filter { id in servers.contains { $0.id == id } }.count
    }

    private var groupIcon: String {
        switch group.type {
        case .urlTest: return "speedometer"
        case .fallback: return "arrow.triangle.2.circlepath"
        case .select: return "hand.tap.fill"
        }
    }

    private var groupColor: Color {
        switch group.type {
        case .urlTest: return Color(red: 0.0, green: 0.85, blue: 0.5)
        case .fallback: return Color(red: 1.0, green: 0.6, blue: 0.2)
        case .select: return Color(red: 0.3, green: 0.5, blue: 1.0)
        }
    }
}

// MARK: - Group Edit

struct GroupEditView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var vpn: VPNManager

    let initialGroup: ProxyGroup?
    let onSave: (ProxyGroup) -> Void

    @State private var name: String
    @State private var type: GroupType
    @State private var selectedServerIDs: Set<UUID>
    @State private var testURL: String
    @State private var testInterval: String

    init(group: ProxyGroup?, onSave: @escaping (ProxyGroup) -> Void) {
        self.initialGroup = group
        self.onSave = onSave
        let g = group ?? ProxyGroup()
        _name = State(initialValue: g.name)
        _type = State(initialValue: g.type)
        _selectedServerIDs = State(initialValue: Set(g.serverIDs))
        _testURL = State(initialValue: g.testURL)
        _testInterval = State(initialValue: "\(g.testInterval)")
    }

    var body: some View {
        NavigationView {
            Form {
                Section("Group") {
                    TextField("Name", text: $name)
                    Picker("Type", selection: $type) {
                        Text("URL Test (auto fastest)").tag(GroupType.urlTest)
                        Text("Fallback (first available)").tag(GroupType.fallback)
                        Text("Select (manual)").tag(GroupType.select)
                    }
                }

                if type == .urlTest || type == .fallback {
                    Section("Test Settings") {
                        TextField("Test URL", text: $testURL)
                            .autocapitalization(.none)
                            .keyboardType(.URL)
                        TextField("Interval (seconds)", text: $testInterval)
                            .keyboardType(.numberPad)
                    }
                }

                Section("Servers") {
                    if vpn.appConfig.servers.isEmpty {
                        Text("Нет серверов. Сначала добавьте серверы.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(vpn.appConfig.servers) { server in
                            HStack {
                                Text(server.name.isEmpty ? server.address : server.name)
                                Spacer()
                                Text(server.proto.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if selectedServerIDs.contains(server.id) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color(red: 0.0, green: 0.85, blue: 1.0))
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if selectedServerIDs.contains(server.id) {
                                    selectedServerIDs.remove(server.id)
                                } else {
                                    selectedServerIDs.insert(server.id)
                                }
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(red: 0.04, green: 0.05, blue: 0.1))
            .navigationTitle(initialGroup == nil ? "New Group" : "Edit Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        var group = initialGroup ?? ProxyGroup()
                        group.name = name
                        group.type = type
                        group.serverIDs = Array(selectedServerIDs)
                        group.testURL = testURL
                        group.testInterval = Int(testInterval) ?? 300
                        onSave(group)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

// MARK: - Helpers

extension GroupType {
    var displayName: String {
        switch self {
        case .urlTest: return "URL Test"
        case .fallback: return "Fallback"
        case .select: return "Select"
        }
    }
}
