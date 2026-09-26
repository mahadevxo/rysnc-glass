import Foundation

/// Decides whether a host is on the local network, where the link is fast
/// enough that compression costs more than it saves: it burns CPU to shrink
/// data a gigabit link would carry anyway, and for photos, video and archives
/// there's nothing left to shrink. 100.64/10 (CGNAT, Tailscale) is left out
/// on purpose — those peers can be on the other side of the world.
enum NetworkClassifier {
    private static var cache: [String: Bool] = [:]
    private static let lock = NSLock()

    static func isLocal(host rawHost: String) -> Bool {
        let host = rawHost.trimmingCharacters(in: .whitespaces).lowercased()
        if let cached = lock.withLock({ cache[host] }) { return cached }
        let result = classify(host)
        lock.withLock { cache[host] = result }
        return result
    }

    private static func classify(_ host: String) -> Bool {
        if host.isEmpty { return false }
        if host == "localhost" || host.hasSuffix(".local") { return true }
        if let literal = isPrivateAddress(host) { return literal }
        // A name: resolve it and go by where it points. A name that doesn't
        // resolve here is treated as remote — the cautious default, since
        // wrongly turning compression off on a slow link costs far more than
        // leaving it on across a fast one.
        let addresses = resolve(host)
        return !addresses.isEmpty && addresses.allSatisfy { isPrivateAddress($0) == true }
    }

    /// nil if `string` isn't an IP address literal.
    static func isPrivateAddress(_ string: String) -> Bool? {
        // Brackets from "[::1]:22"-style input, and an IPv6 zone ("%en0").
        let trimmed = String(string.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).split(separator: "%").first ?? "")
        var v4 = in_addr()
        if inet_pton(AF_INET, trimmed, &v4) == 1 {
            let b = withUnsafeBytes(of: v4.s_addr) { Array($0) }  // network byte order
            switch (b[0], b[1]) {
            case (10, _), (127, _), (192, 168), (169, 254): return true
            case (172, 16...31): return true
            default: return false
            }
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, trimmed, &v6) == 1 {
            let b = withUnsafeBytes(of: v6) { Array($0) }
            if b.dropLast().allSatisfy({ $0 == 0 }) && b.last == 1 { return true }  // ::1
            if b[0] & 0xFE == 0xFC { return true }  // fc00::/7 unique local
            if b[0] == 0xFE && b[1] & 0xC0 == 0x80 { return true }  // fe80::/10 link local
            return false
        }
        return nil
    }

    private static func resolve(_ host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return [] }
        defer { freeaddrinfo(first) }
        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                addresses.append(String(cString: buffer))
            }
            cursor = info.pointee.ai_next
        }
        return addresses
    }
}
