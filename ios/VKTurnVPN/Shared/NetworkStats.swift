import Foundation

/// Reads network interface byte counters from the system.
/// Works for utun (VPN tunnel) interfaces.
struct NetworkStats {
    var bytesIn: UInt64 = 0
    var bytesOut: UInt64 = 0

    /// Get current byte counters for all utun interfaces (VPN tunnel).
    static func getVPNStats() -> NetworkStats {
        var stats = NetworkStats()
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else {
            return stats
        }
        defer { freeifaddrs(ifaddrPtr) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let addr = cursor {
            let name = String(cString: addr.pointee.ifa_name)

            // utun interfaces are VPN tunnels
            if name.hasPrefix("utun") {
                if let data = addr.pointee.ifa_data {
                    // ifa_data points to if_data struct for AF_LINK
                    let ifData = data.assumingMemoryBound(to: if_data.self).pointee
                    stats.bytesIn += UInt64(ifData.ifi_ibytes)
                    stats.bytesOut += UInt64(ifData.ifi_obytes)
                }
            }

            cursor = addr.pointee.ifa_next
        }

        return stats
    }

    /// Format bytes to human-readable string
    static func formatSpeed(_ bytesPerSec: UInt64) -> String {
        if bytesPerSec < 1024 {
            return "\(bytesPerSec) B/s"
        } else if bytesPerSec < 1024 * 1024 {
            return String(format: "%.1f KB/s", Double(bytesPerSec) / 1024)
        } else {
            return String(format: "%.1f MB/s", Double(bytesPerSec) / (1024 * 1024))
        }
    }

    static func formatBytes(_ bytes: UInt64) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024)
        } else if bytes < 1024 * 1024 * 1024 {
            return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
        } else {
            return String(format: "%.2f GB", Double(bytes) / (1024 * 1024 * 1024))
        }
    }
}
