import Foundation

/// Base URLs for the NAMS backend services. API and auth bases include the
/// `/v1` version prefix (matching the SDK's endpoint convention); request
/// paths in NAMSClient are version-less.
///
/// Production values are compiled in. Two override layers reroute a build at
/// the staging or local stack without surfacing an environment picker in the
/// UI (environment wins over defaults):
///
///     # bundled app
///     defaults write com.neo4j-labs.inams NAMSAPIBaseURL http://localhost:8080/v1
///
///     # `swift run` development binary (no bundle id, so the defaults
///     # domain above does not apply - use the environment instead)
///     NAMS_API_BASE_URL=http://localhost:8080/v1 \
///     NAMS_AUTH_BASE_URL=http://localhost:8081/v1 swift run iNAMS
public struct NAMSConfig: Equatable, Sendable {
    public var apiBase: URL
    public var authBase: URL
    public var mcpBase: URL

    public init(apiBase: URL, authBase: URL, mcpBase: URL) {
        self.apiBase = apiBase
        self.authBase = authBase
        self.mcpBase = mcpBase
    }

    // One public gateway fronts every service; the REST surface lives under
    // /v1 (same endpoint the SDK defaults to) and MCP under /mcp.
    public static let production = NAMSConfig(
        apiBase: URL(string: "https://memory.neo4jlabs.com/v1")!,
        authBase: URL(string: "https://memory.neo4jlabs.com/v1")!,
        mcpBase: URL(string: "https://memory.neo4jlabs.com/mcp")!
    )

    /// The `make dev-all` stack from the project-gaylord monorepo.
    public static let localDev = NAMSConfig(
        apiBase: URL(string: "http://localhost:8080/v1")!,
        authBase: URL(string: "http://localhost:8081/v1")!,
        mcpBase: URL(string: "http://localhost:9090")!
    )

    public static func resolved(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> NAMSConfig {
        var config = NAMSConfig.production
        func override(_ envKey: String, _ defaultsKey: String) -> URL? {
            if let s = environment[envKey], let url = URL(string: s) { return url }
            if let s = defaults.string(forKey: defaultsKey), let url = URL(string: s) { return url }
            return nil
        }
        if let url = override("NAMS_API_BASE_URL", "NAMSAPIBaseURL") { config.apiBase = url }
        if let url = override("NAMS_AUTH_BASE_URL", "NAMSAuthBaseURL") { config.authBase = url }
        if let url = override("NAMS_MCP_BASE_URL", "NAMSMCPBaseURL") { config.mcpBase = url }
        return config
    }
}
