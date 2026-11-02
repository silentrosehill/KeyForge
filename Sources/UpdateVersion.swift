import Foundation

/// Only stable releases from this app's repository are considered.
enum UpdateVersion {
    static func numbers(_ value: String) -> [Int]? {
        let text = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var result: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(part) else { return nil }
            result.append(number)
        }
        while result.count < 4 { result.append(0) }
        return result
    }
    static func isNewer(_ latest: String, than installed: String) -> Bool {
        guard let left = numbers(latest), let right = numbers(installed) else { return false }
        return right.lexicographicallyPrecedes(left)
    }
}

