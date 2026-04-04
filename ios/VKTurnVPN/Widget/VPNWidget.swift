import WidgetKit
import SwiftUI

// MARK: - Timeline Provider

struct VPNStatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> VPNStatusEntry {
        VPNStatusEntry(date: Date(), isConnected: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (VPNStatusEntry) -> Void) {
        let connected = UserDefaults(suiteName: "group.com.swinter.vpn")?.bool(forKey: "vpn_connected") ?? false
        completion(VPNStatusEntry(date: Date(), isConnected: connected))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<VPNStatusEntry>) -> Void) {
        let connected = UserDefaults(suiteName: "group.com.swinter.vpn")?.bool(forKey: "vpn_connected") ?? false
        let entry = VPNStatusEntry(date: Date(), isConnected: connected)
        // Refresh every 5 minutes
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 5, to: Date())!
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
}

// MARK: - Entry

struct VPNStatusEntry: TimelineEntry {
    let date: Date
    let isConnected: Bool
}

// MARK: - Widget View

struct VPNWidgetView: View {
    var entry: VPNStatusEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        ZStack {
            // Background
            Color(red: 0.04, green: 0.05, blue: 0.1)

            VStack(spacing: 8) {
                // Status circle
                ZStack {
                    Circle()
                        .fill(entry.isConnected
                              ? Color(red: 0.29, green: 0.87, blue: 0.5).opacity(0.15)
                              : Color.white.opacity(0.05))
                        .frame(width: 48, height: 48)

                    Circle()
                        .stroke(entry.isConnected
                                ? Color(red: 0.29, green: 0.87, blue: 0.5)
                                : Color.white.opacity(0.2),
                                lineWidth: 2)
                        .frame(width: 48, height: 48)

                    Image(systemName: entry.isConnected ? "shield.checkered" : "shield.slash")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(entry.isConnected
                                         ? Color(red: 0.29, green: 0.87, blue: 0.5)
                                         : .white.opacity(0.4))
                }

                // Status text
                Text(entry.isConnected ? "VPN ON" : "VPN OFF")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(entry.isConnected
                                     ? Color(red: 0.29, green: 0.87, blue: 0.5)
                                     : .white.opacity(0.5))

                if family != .systemSmall {
                    Text(entry.isConnected ? "Защищено" : "Нажми для включения")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
        }
        .widgetURL(URL(string: "swinter://toggle"))
    }
}

// MARK: - Widget Definition

struct VPNWidget: Widget {
    let kind: String = "VPNWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: VPNStatusProvider()) { entry in
            if #available(iOSApplicationExtension 17.0, *) {
                VPNWidgetView(entry: entry)
                    .containerBackground(Color(red: 0.04, green: 0.05, blue: 0.1), for: .widget)
            } else {
                VPNWidgetView(entry: entry)
                    .padding()
                    .background(Color(red: 0.04, green: 0.05, blue: 0.1))
            }
        }
        .configurationDisplayName("VPN Status")
        .description("Быстрый доступ к VPN")
        .supportedFamilies([.systemSmall])
    }
}

// MARK: - Widget Bundle

@main
struct VPNWidgetBundle: WidgetBundle {
    var body: some Widget {
        VPNWidget()
    }
}
