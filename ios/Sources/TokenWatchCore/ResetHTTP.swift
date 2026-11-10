import Foundation

enum ResetHTTP {
    static func load(_ request: URLRequest, session: URLSession) async throws -> (Data, HTTPURLResponse) {
        let (bytes, rawResponse) = try await session.bytes(for: request)
        guard let response = rawResponse as? HTTPURLResponse else {
            throw ResetError.invalidResponse("Missing HTTP response.")
        }
        guard response.expectedContentLength <= 524_288 else {
            throw ResetError.invalidResponse("Response exceeds 512 KiB.")
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 524_288 else {
                throw ResetError.invalidResponse("Response exceeds 512 KiB.")
            }
            data.append(byte)
        }
        return (data, response)
    }

    static func retryDelay(_ value: String?, now: Date) -> Int {
        if let value, let seconds = Int(value) { return max(60, seconds) }
        if let value, let date = HTTPDate.parse(value) {
            return max(60, Int(date.timeIntervalSince(now)))
        }
        return 300
    }
}

private enum HTTPDate {
    static func parse(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}
