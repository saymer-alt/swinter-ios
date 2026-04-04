import SwiftUI

struct TabRootView: View {
    @EnvironmentObject var vpn: VPNManager
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeTab()
                .tabItem {
                    Image(systemName: "shield.fill")
                    Text("Home")
                }
                .tag(0)

            ServerListView()
                .tabItem {
                    Image(systemName: "server.rack")
                    Text("Servers")
                }
                .tag(1)

            ConfigTab()
                .tabItem {
                    Image(systemName: "slider.horizontal.3")
                    Text("Config")
                }
                .tag(2)

            SettingsView()
                .tabItem {
                    Image(systemName: "gearshape.fill")
                    Text("Settings")
                }
                .tag(3)
        }
        .tint(Color(red: 0.0, green: 0.85, blue: 1.0))
    }
}

// MARK: - Home Tab

struct HomeTab: View {
    @EnvironmentObject var vpn: VPNManager

    var body: some View {
        ZStack {
            LiquidBackground(connectionState: vpn.state)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Top bar
                HStack {
                    Text("Swinter")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)

                // Main content (orb + routing + active server + favorites)
                MainView()
            }
            .animation(.spring(response: 0.6, dampingFraction: 0.8), value: vpn.state)
        }
    }
}
