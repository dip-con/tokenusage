import Foundation

public enum GrokUsageClientError: Error, Equatable, Sendable, LocalizedError {
    case unauthorized
    case rateLimited
    case networkFailure
    case malformedResponse
    case unexpectedHTTPStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            "Grok 로그인이 만료되었습니다. 다시 로그인해 주세요."
        case .rateLimited:
            "Grok 사용량 조회가 제한되었습니다."
        case .networkFailure:
            "Grok 사용량 조회 요청이 실패했습니다."
        case .malformedResponse:
            "Grok 사용량 응답을 해석할 수 없습니다."
        case let .unexpectedHTTPStatus(status):
            "Grok 사용량 조회가 HTTP \(status) 로 실패했습니다."
        }
    }
}

/// Reads a SuperGrok account's subscription allowance through the Grok CLI's own backend.
///
/// `cli-chat-proxy.grok.com` is the undocumented service the official `grok` CLI talks to; xAI
/// publishes no usage API for subscriptions, so these routes may change without notice.
public struct GrokUsageClient: Sendable {
    public static let baseURL = URL(string: "https://cli-chat-proxy.grok.com/v1/")!

    private let session: any URLSessionProtocol
    private let baseURL: URL
    private let now: @Sendable () -> Date

    public init(
        session: any URLSessionProtocol = URLSession.shared,
        baseURL: URL = GrokUsageClient.baseURL,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.session = session
        self.baseURL = baseURL
        self.now = now
    }

    public func usage(accessToken: String) async throws -> UsageSnapshot {
        let data = try await get("billing?format=credits", accessToken: accessToken)
        return try GrokUsageDecoder.decode(data, capturedAt: now())
    }

    public func subscriptionTier(accessToken: String) async throws -> String? {
        let data = try await get("settings", accessToken: accessToken)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GrokUsageClientError.malformedResponse
        }
        return (root["subscription_tier_display"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private func get(_ path: String, accessToken: String) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw GrokUsageClientError.malformedResponse
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "x-xai-token-auth")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GrokUsageClientError.networkFailure
        }
        guard let http = response as? HTTPURLResponse else {
            throw GrokUsageClientError.malformedResponse
        }
        switch http.statusCode {
        case 200...299:
            return data
        case 401, 403:
            throw GrokUsageClientError.unauthorized
        case 429:
            throw GrokUsageClientError.rateLimited
        default:
            throw GrokUsageClientError.unexpectedHTTPStatus(http.statusCode)
        }
    }
}

enum GrokUsageDecoder {
    static func decode(_ data: Data, capturedAt: Date) throws -> UsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let config = root["config"] as? [String: Any] else {
            throw GrokUsageClientError.malformedResponse
        }
        let period = config["currentPeriod"] as? [String: Any]
        let start = (period?["start"] as? String).flatMap(date(from:))
            ?? (config["billingPeriodStart"] as? String).flatMap(date(from:))
        let end = (period?["end"] as? String).flatMap(date(from:))
            ?? (config["billingPeriodEnd"] as? String).flatMap(date(from:))

        let usedPercent: Double
        if let percent = number(config["creditUsagePercent"]) {
            usedPercent = percent
        } else if let cap = number((config["onDemandCap"] as? [String: Any])?["val"]), cap > 0,
                  let used = number((config["onDemandUsed"] as? [String: Any])?["val"]) {
            usedPercent = used / cap * 100
        } else if let start, let end, start <= capturedAt, capturedAt < end {
            // The backend serialises protobuf, which omits a zero percentage; grok.com's own
            // client reads the missing field of a current period as nothing used yet.
            usedPercent = 0
        } else {
            throw GrokUsageClientError.malformedResponse
        }
        guard usedPercent.isFinite else { throw GrokUsageClientError.malformedResponse }

        let duration = start.flatMap { start in end.map { $0.timeIntervalSince(start) } }
        return UsageSnapshot(
            capturedAt: capturedAt,
            weekly: QuotaWindow(
                remainingPercent: min(100, max(0, 100 - usedPercent)),
                resetsAt: end,
                windowDuration: duration.flatMap { $0 > 0 ? $0 : nil }
            )
        )
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            number.doubleValue
        case let string as String:
            Double(string)
        default:
            nil
        }
    }

    private static func date(from string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}
