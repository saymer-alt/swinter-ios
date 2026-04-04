import Foundation

/// Parses Shadowrocket .conf and Swinter .conf formats.
/// Returns parsed routing rules, DNS config, proxy groups, and optional TURN config.
struct ParsedConfig {
    var rules: [RoutingRule] = []
    var dns: DNSConfig = DNSConfig()
    var groups: [ProxyGroup] = []
    var turnOverlay: TurnOverlayConfig? = nil
    var updateURL: String = ""
    var hosts: [String: String] = [:]
}

struct ConfigParser {

    /// Parse a Shadowrocket/Swinter .conf string.
    static func parse(_ content: String) -> ParsedConfig {
        var result = ParsedConfig()
        var currentSection = ""

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            // Section headers
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                currentSection = String(trimmed.dropFirst().dropLast()).lowercased()
                continue
            }

            switch currentSection {
            case "general":
                parseGeneral(trimmed, into: &result)
            case "turn":
                parseTURN(trimmed, into: &result)
            case "proxy group":
                parseProxyGroup(trimmed, into: &result)
            case "rule":
                parseRule(trimmed, into: &result)
            case "host":
                parseHost(trimmed, into: &result)
            default:
                break // ignore unknown sections (URL Rewrite, etc.)
            }
        }

        return result
    }

    /// Parse from URL (async). Downloads and parses config + RULE-SET URLs.
    static func parseFromURL(_ urlString: String) async -> ParsedConfig? {
        guard let url = URL(string: urlString) else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let content = String(data: data, encoding: .utf8) else { return nil }
            var config = parse(content)

            // Resolve RULE-SET URLs
            config.rules = await resolveRuleSets(config.rules)

            return config
        } catch {
            print("[ConfigParser] Failed to fetch \(urlString): \(error)")
            return nil
        }
    }

    // MARK: - Section Parsers

    private static func parseGeneral(_ line: String, into result: inout ParsedConfig) {
        let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return }
        let key = parts[0].lowercased()
        let value = parts[1]

        switch key {
        case "dns-server":
            let servers = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            result.dns.servers = servers.filter { !$0.hasPrefix("https://") }
            // First DoH URL
            if let doh = servers.first(where: { $0.hasPrefix("https://") }) {
                result.dns.dohURL = doh
            }
        case "fallback-dns-server":
            if value != "system" {
                result.dns.fallbackServers = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            }
        case "update-url":
            result.updateURL = value
        default:
            break
        }
    }

    private static func parseTURN(_ line: String, into result: inout ParsedConfig) {
        let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return }
        let key = parts[0].lowercased()
        let value = parts[1]

        if result.turnOverlay == nil {
            result.turnOverlay = TurnOverlayConfig()
        }

        switch key {
        case "source":
            result.turnOverlay?.source = value == "vk" ? .vk : .max
        case "target-user-id":
            result.turnOverlay?.maxTargetUserID = value
        case "use-udp":
            result.turnOverlay?.useUDP = value.lowercased() == "true"
        case "num-conns":
            result.turnOverlay?.numConns = Int(value) ?? 4
        case "vk-link":
            result.turnOverlay?.vkLink = value
        default:
            break
        }
    }

    private static func parseProxyGroup(_ line: String, into result: inout ParsedConfig) {
        // Format: NAME = type, param1=value1, param2=value2
        let mainParts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard mainParts.count == 2 else { return }

        let name = mainParts[0]
        let params = mainParts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let typeStr = params.first else { return }

        var group = ProxyGroup()
        group.name = name

        switch typeStr.lowercased() {
        case "url-test": group.type = .urlTest
        case "fallback": group.type = .fallback
        case "select": group.type = .select
        default: group.type = .select
        }

        for param in params.dropFirst() {
            let kv = param.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2 else { continue }
            switch kv[0].lowercased() {
            case "interval": group.testInterval = Int(kv[1]) ?? 300
            case "timeout": break // tolerance
            case "url": group.testURL = kv[1]
            default: break
            }
        }

        result.groups.append(group)
    }

    private static func parseRule(_ line: String, into result: inout ParsedConfig) {
        let parts = line.split(separator: ",", maxSplits: 2).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2 else { return }

        let typeStr = parts[0].uppercased()
        let value: String
        let actionStr: String

        if typeStr == "FINAL" {
            // FINAL,PROXY or FINAL,DIRECT
            value = ""
            actionStr = parts[1].uppercased()
        } else if typeStr == "RULE-SET" {
            // RULE-SET,URL,ACTION
            guard parts.count >= 3 else { return }
            value = parts[1] // URL
            actionStr = parts[2].uppercased().replacingOccurrences(of: ",NO-RESOLVE", with: "")
            // Store as special rule that will be resolved later
            let action = parseAction(actionStr)
            result.rules.append(RoutingRule(type: .domainSuffix, value: "RULE-SET:\(value):\(actionStr)", action: action))
            return
        } else {
            guard parts.count >= 3 else { return }
            value = parts[1]
            actionStr = parts[2].uppercased().replacingOccurrences(of: ",NO-RESOLVE", with: "")
        }

        let action = parseAction(actionStr)

        let type: RuleType
        switch typeStr {
        case "DOMAIN": type = .domain
        case "DOMAIN-SUFFIX": type = .domainSuffix
        case "DOMAIN-KEYWORD": type = .domainKeyword
        case "IP-CIDR", "IP-CIDR6": type = .ipCidr
        case "GEOIP": type = .geoip
        case "FINAL": type = .final
        case "IP-ASN": type = .ipCidr // map to ipCidr for now
        default: return // skip unsupported types
        }

        result.rules.append(RoutingRule(type: type, value: value, action: action))
    }

    private static func parseHost(_ line: String, into result: inout ParsedConfig) {
        let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return }
        result.hosts[parts[0]] = parts[1]
    }

    private static func parseAction(_ str: String) -> RuleAction {
        switch str.trimmingCharacters(in: .whitespaces) {
        case "PROXY": return .proxy
        case "DIRECT": return .direct
        case "REJECT", "REJECT-NO-DROP": return .reject
        default: return .proxy
        }
    }

    // MARK: - RULE-SET Resolution

    /// Download and parse RULE-SET URLs, expanding them into individual rules.
    static func resolveRuleSets(_ rules: [RoutingRule]) async -> [RoutingRule] {
        var resolved: [RoutingRule] = []

        for rule in rules {
            if rule.value.hasPrefix("RULE-SET:") {
                // Parse "RULE-SET:URL:ACTION"
                let parts = rule.value.dropFirst("RULE-SET:".count).split(separator: ":", maxSplits: 1)
                guard parts.count >= 1 else {
                    resolved.append(rule)
                    continue
                }
                let url = String(parts[0])
                let action = rule.action

                // Download rule set
                if let setRules = await downloadRuleSet(url, action: action) {
                    resolved.append(contentsOf: setRules)
                }
            } else {
                resolved.append(rule)
            }
        }

        return resolved
    }

    private static func downloadRuleSet(_ urlString: String, action: RuleAction) async -> [RoutingRule]? {
        guard let url = URL(string: urlString) else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let content = String(data: data, encoding: .utf8) else { return nil }

            var rules: [RoutingRule] = []
            for line in content.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

                let parts = trimmed.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count >= 2 else { continue }

                let typeStr = parts[0].uppercased()
                let value = parts[1].replacingOccurrences(of: ",no-resolve", with: "")

                let type: RuleType
                switch typeStr {
                case "DOMAIN": type = .domain
                case "DOMAIN-SUFFIX": type = .domainSuffix
                case "DOMAIN-KEYWORD": type = .domainKeyword
                case "IP-CIDR", "IP-CIDR6": type = .ipCidr
                case "IP-ASN": type = .ipCidr
                default: continue
                }

                rules.append(RoutingRule(type: type, value: value, action: action))
            }

            print("[ConfigParser] Downloaded \(rules.count) rules from \(urlString)")
            return rules
        } catch {
            print("[ConfigParser] Failed to download rule set \(urlString): \(error)")
            return nil
        }
    }
}
