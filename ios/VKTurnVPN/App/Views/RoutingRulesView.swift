import SwiftUI

struct RoutingRulesView: View {
    @EnvironmentObject var vpn: VPNManager
    @State private var showAddRule = false

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("ROUTING RULES")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(.white.opacity(0.35))
                Spacer()

                // Preset button
                Menu {
                    Button("RU Direct (рос. сайты напрямую)") { applyPreset(.ruDirect) }
                    Button("Blocked Proxy (заблокированные через прокси)") { applyPreset(.blockedProxy) }
                    Button("Очистить правила") { vpn.clearRules() }
                } label: {
                    Image(systemName: "text.badge.plus")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.5))
                }

                Button { showAddRule = true } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Color(red: 0.0, green: 0.85, blue: 1.0))
                }
            }
            .padding(.horizontal, 4)

            if vpn.appConfig.routingRules.isEmpty {
                Text("Нет правил. Весь трафик идёт через прокси. Добавьте правила или выберите пресет.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.3))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            } else {
                ForEach(vpn.appConfig.routingRules) { rule in
                    RuleRow(rule: rule) {
                        vpn.removeRule(rule.id)
                    } onToggle: { enabled in
                        vpn.toggleRule(rule.id, enabled: enabled)
                    }
                }
            }
        }
        .sheet(isPresented: $showAddRule) {
            RuleEditView { vpn.addRule($0) }
        }
    }

    private func applyPreset(_ preset: RulePreset) {
        let rules = preset.rules
        for rule in rules {
            vpn.addRule(rule)
        }
    }
}

// MARK: - Rule Row

struct RuleRow: View {
    let rule: RoutingRule
    let onDelete: () -> Void
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { onToggle($0) }
            ))
            .labelsHidden()
            .scaleEffect(0.8)

            Text(rule.type.rawValue)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 90, alignment: .leading)

            Text(rule.value)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(rule.enabled ? 0.8 : 0.35))
                .lineLimit(1)

            Spacer()

            Text(rule.action.rawValue)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(actionColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(actionColor.opacity(0.15), in: Capsule())

            Button { onDelete() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.2))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var actionColor: Color {
        switch rule.action {
        case .proxy: return Color(red: 0.0, green: 0.85, blue: 1.0)
        case .direct: return Color(red: 0.0, green: 0.85, blue: 0.5)
        case .reject: return Color(red: 0.9, green: 0.3, blue: 0.3)
        }
    }
}

// MARK: - Rule Edit

struct RuleEditView: View {
    @Environment(\.dismiss) var dismiss
    let onSave: (RoutingRule) -> Void

    @State private var type: RuleType = .domainSuffix
    @State private var value: String = ""
    @State private var action: RuleAction = .proxy

    var body: some View {
        NavigationView {
            Form {
                Picker("Type", selection: $type) {
                    ForEach(RuleType.allCases, id: \.self) { t in
                        Text(t.rawValue).tag(t)
                    }
                }

                TextField("Value (e.g. google.com, CN, 10.0.0.0/8)", text: $value)
                    .autocapitalization(.none)

                Picker("Action", selection: $action) {
                    ForEach(RuleAction.allCases, id: \.self) { a in
                        Text(a.rawValue).tag(a)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(red: 0.04, green: 0.05, blue: 0.1))
            .navigationTitle("New Rule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add") {
                        onSave(RoutingRule(type: type, value: value, action: action))
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(value.isEmpty)
                }
            }
        }
    }
}

// MARK: - Presets

enum RulePreset {
    case ruDirect
    case blockedProxy

    var rules: [RoutingRule] {
        switch self {
        case .ruDirect:
            return [
                RoutingRule(type: .geoip, value: "RU", action: .direct),
                RoutingRule(type: .domainSuffix, value: "ru", action: .direct),
                RoutingRule(type: .domainSuffix, value: "yandex.com", action: .direct),
                RoutingRule(type: .domainSuffix, value: "vk.com", action: .direct),
                RoutingRule(type: .domainSuffix, value: "mail.ru", action: .direct),
            ]
        case .blockedProxy:
            return [
                RoutingRule(type: .domainKeyword, value: "google", action: .proxy),
                RoutingRule(type: .domainKeyword, value: "youtube", action: .proxy),
                RoutingRule(type: .domainKeyword, value: "facebook", action: .proxy),
                RoutingRule(type: .domainSuffix, value: "instagram.com", action: .proxy),
                RoutingRule(type: .domainSuffix, value: "twitter.com", action: .proxy),
                RoutingRule(type: .domainSuffix, value: "x.com", action: .proxy),
                RoutingRule(type: .domainSuffix, value: "telegram.org", action: .proxy),
                RoutingRule(type: .domainSuffix, value: "t.me", action: .proxy),
                RoutingRule(type: .domainSuffix, value: "openai.com", action: .proxy),
                RoutingRule(type: .domainSuffix, value: "chatgpt.com", action: .proxy),
            ]
        }
    }
}
