import Foundation
import Network

@MainActor
final class MobileNetworkProvider {
    enum NetworkError: LocalizedError {
        case invalidURL
        case localNetworkTargetDenied
        case invalidMethod
        case responseTooLarge

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "http_probe requires an absolute HTTP or HTTPS URL."
            case .localNetworkTargetDenied: return "http_probe is internet-only and refuses loopback/private/local-network targets."
            case .invalidMethod: return "http_probe method must be GET or HEAD."
            case .responseTooLarge: return "The HTTP response sample exceeded the mobile probe limit."
            }
        }
    }

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.xycdev.lsmmobileworker.network-path")
    private var path: NWPath?

    init() {
        monitor.pathUpdateHandler = { [weak self] value in
            Task { @MainActor in self?.path = value }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    func status() -> [String: Any] {
        guard let path else {
            return ["status": "initializing", "interfaces": []]
        }
        var interfaces: [String] = []
        for (name, type) in [
            ("wifi", NWInterface.InterfaceType.wifi),
            ("cellular", .cellular),
            ("wired_ethernet", .wiredEthernet),
            ("loopback", .loopback),
            ("other", .other),
        ] where path.usesInterfaceType(type) {
            interfaces.append(name)
        }
        return [
            "status": pathStatusName(path.status),
            "interfaces": interfaces,
            "expensive": path.isExpensive,
            "constrained": path.isConstrained,
            "supports_ipv4": path.supportsIPv4,
            "supports_ipv6": path.supportsIPv6,
            "supports_dns": path.supportsDNS,
        ]
    }

    func httpProbe(_ arguments: [String: Any]) async throws -> [String: Any] {
        guard let raw = arguments["url"] as? String,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else {
            throw NetworkError.invalidURL
        }
        guard !isLocalNetworkHost(host) else { throw NetworkError.localNetworkTargetDenied }
        let method = ((arguments["method"] as? String) ?? "HEAD").uppercased()
        guard method == "GET" || method == "HEAD" else { throw NetworkError.invalidMethod }
        let timeout = min(max((arguments["timeout_s"] as? NSNumber)?.doubleValue ?? 10, 1), 20)
        let maxSample = min(max((arguments["max_sample_bytes"] as? NSNumber)?.intValue ?? 4096, 0), 64 * 1024)
        let includeSample = (arguments["include_sample"] as? Bool) ?? false

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("LSMMobileWorker/1", forHTTPHeaderField: "User-Agent")

        let start = ContinuousClock.now
        let (bytes, response) = try await session.bytes(for: request)
        let headersMs = start.duration(to: .now).milliseconds
        guard let http = response as? HTTPURLResponse else { throw NetworkError.invalidURL }
        var sample = Data()
        if method == "GET" && maxSample > 0 {
            for try await byte in bytes {
                if sample.count >= maxSample { break }
                sample.append(byte)
            }
        }
        let totalMs = start.duration(to: .now).milliseconds
        var result: [String: Any] = [
            "url": raw,
            "final_url": http.url?.absoluteString ?? raw,
            "method": method,
            "status_code": http.statusCode,
            "headers_latency_ms": headersMs,
            "elapsed_ms": totalMs,
            "content_type": http.value(forHTTPHeaderField: "Content-Type") ?? NSNull(),
            "sample_bytes": sample.count,
        ]
        if includeSample, !sample.isEmpty,
           let text = String(data: sample, encoding: .utf8) {
            result["sample_text"] = text
        }
        return result
    }

    private func isLocalNetworkHost(_ host: String) -> Bool {
        let value = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if value == "localhost" || value.hasSuffix(".localhost") || value.hasSuffix(".local") || value.hasSuffix(".home.arpa") {
            return true
        }
        if let address = IPv4Address(value) {
            let b = [UInt8](address.rawValue)
            guard b.count == 4 else { return true }
            return b[0] == 0 || b[0] == 10 || b[0] == 127 ||
                (b[0] == 169 && b[1] == 254) ||
                (b[0] == 172 && (16...31).contains(Int(b[1]))) ||
                (b[0] == 192 && b[1] == 168) ||
                (b[0] == 100 && (64...127).contains(Int(b[1])))
        }
        if let address = IPv6Address(value) {
            let b = [UInt8](address.rawValue)
            guard b.count == 16 else { return true }
            let loopback = b.dropLast().allSatisfy { $0 == 0 } && b.last == 1
            let uniqueLocal = (b[0] & 0xfe) == 0xfc
            let linkLocal = b[0] == 0xfe && (b[1] & 0xc0) == 0x80
            return loopback || uniqueLocal || linkLocal
        }
        return false
    }

    private func pathStatusName(_ status: NWPath.Status) -> String {
        switch status {
        case .satisfied: return "satisfied"
        case .unsatisfied: return "unsatisfied"
        case .requiresConnection: return "requires_connection"
        @unknown default: return "unknown"
        }
    }
}

private extension Duration {
    var milliseconds: Double {
        let components = self.components
        return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
