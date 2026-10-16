import AppKit
import Foundation
import TokenUsageCore

struct GrokExecutableResolver: Sendable {
    func resolve(environment: [String: String]) throws -> URL {
        let fileManager = FileManager.default
        if let override = environment["TOKENUSAGE_GROK_PATH"], !override.isEmpty {
            let url = URL(fileURLWithPath: override, isDirectory: false)
            guard fileManager.isExecutableFile(atPath: url.resolvingSymlinksInPath().path) else {
                throw GrokProfileManagerError.loginUnavailable
            }
            return url
        }
        var directories = environment["PATH"]?
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init) ?? []
        if let home = environment["HOME"], !home.isEmpty {
            directories.append(contentsOf: ["\(home)/.grok/bin", "\(home)/.local/bin", "\(home)/bin"])
        }
        directories.append(contentsOf: ["/opt/homebrew/bin", "/usr/local/bin"])
        var visited = Set<String>()
        for directory in directories where visited.insert(directory).inserted {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent("grok", isDirectory: false)
            var isDirectory: ObjCBool = false
            let path = candidate.resolvingSymlinksInPath().path
            if fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
               !isDirectory.boolValue,
               fileManager.isExecutableFile(atPath: path) {
                return candidate
            }
        }
        throw GrokProfileManagerError.loginUnavailable
    }
}

/// Runs `grok login --device-auth` in a throwaway `GROK_HOME` and opens the x.ai sign-in page
/// it prints; the user approves the pre-filled code in the browser.
final class SystemGrokLoginRunner: GrokLoginRunning, @unchecked Sendable {
    typealias BrowserOpener = @Sendable (URL) -> Bool

    private let resolver: GrokExecutableResolver
    private let environment: [String: String]
    private let browserOpener: BrowserOpener
    let attemptController: CodexLoginAttemptController

    init(
        resolver: GrokExecutableResolver = GrokExecutableResolver(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        browserOpener: @escaping BrowserOpener = { NSWorkspace.shared.open($0) },
        attemptController: CodexLoginAttemptController = CodexLoginAttemptController()
    ) {
        self.resolver = resolver
        self.environment = environment
        self.browserOpener = browserOpener
        self.attemptController = attemptController
    }

    func runGrokLogin(grokHome: URL) async throws -> GrokLoginOutcome {
        let executable = try resolver.resolve(environment: environment)
        let process = OwnedProcess(
            executable: executable,
            arguments: [
                "login",
                "--device-auth",
                "--leader-socket",
                grokHome.appendingPathComponent("leader.sock").path,
            ],
            environment: Self.loginEnvironment(environment, grokHome: grokHome)
        )
        let observer = GrokLoginOutputObserver(
            attemptController: attemptController,
            browserOpener: browserOpener
        )
        process.setOutputHandler { observer.consume($0) }
        attemptController.begin {
            observer.cancel()
            process.terminate()
        }
        defer { attemptController.clear() }
        do {
            try process.start()
        } catch {
            attemptController.clear()
            throw error
        }
        return await withTaskCancellationHandler {
            let status = await process.waitUntilExit()
            if Task.isCancelled || observer.wasCancelled { return .cancelled }
            if status == 0 { return .completed }
            return .failed(terminationStatus: status)
        } onCancel: {
            process.terminate()
        }
    }

    static func loginEnvironment(
        _ environment: [String: String],
        grokHome: URL
    ) -> [String: String] {
        var isolated = environment
        isolated["GROK_HOME"] = grokHome.path
        // An inherited key would let the CLI skip the sign-in this flow exists for.
        isolated["XAI_API_KEY"] = nil
        isolated["GROK_AUTH_PROVIDER_COMMAND"] = nil
        isolated["GROK_OIDC_ISSUER"] = nil
        isolated["GROK_OIDC_CLIENT_ID"] = nil
        return isolated
    }
}

final class GrokLoginOutputObserver: @unchecked Sendable {
    private static let urlExpression = try! NSRegularExpression(
        pattern: #"https://[^\s<>"'\x00-\x1f]+"#,
        options: [.caseInsensitive]
    )
    private let lock = NSLock()
    private let attemptController: CodexLoginAttemptController
    private let browserOpener: SystemGrokLoginRunner.BrowserOpener
    private var scanTail = ""
    private var openedURL: URL?
    private var didCancel = false

    init(
        attemptController: CodexLoginAttemptController,
        browserOpener: @escaping SystemGrokLoginRunner.BrowserOpener
    ) {
        self.attemptController = attemptController
        self.browserOpener = browserOpener
    }

    var wasCancelled: Bool { lock.withLock { didCancel } }

    func cancel() {
        lock.withLock { didCancel = true }
    }

    @discardableResult
    func consume(_ data: Data) -> Bool {
        let chunk = String(decoding: data, as: UTF8.self)
        let url: URL? = lock.withLock {
            guard openedURL == nil else { return nil }
            let candidateText = scanTail + chunk
            scanTail = String(candidateText.suffix(2_048))
            let range = NSRange(candidateText.startIndex..., in: candidateText)
            for match in Self.urlExpression.matches(in: candidateText, range: range) {
                guard let matchRange = Range(match.range, in: candidateText) else { continue }
                let raw = String(candidateText[matchRange]).trimmingCharacters(
                    in: CharacterSet(charactersIn: ").,;]}")
                )
                guard let url = URL(string: raw), Self.isAllowed(url) else { continue }
                openedURL = url
                return url
            }
            return nil
        }
        guard let url else { return false }
        _ = attemptController.open(url, using: browserOpener)
        return true
    }

    static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else {
            return false
        }
        return host == "x.ai" || host.hasSuffix(".x.ai")
    }
}
