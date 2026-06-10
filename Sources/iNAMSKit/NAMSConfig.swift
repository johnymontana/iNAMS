import Foundation

/// Base URLs for the NAMS backend services.
///
/// Production values are compiled in; `UserDefaults` overrides
/// (`NAMSAPIBaseURL`, `NAMSAuthBaseURL`, `NAMSMCPBaseURL`) reroute a build at
/// the staging or local stack without surfacing an environment picker in the
/// UI:
///
///     defaults write com.neo4j-labs.inams NAMSAPIBaseURL http://localhost:8080
public struct NAMSConfig: Equatable, Sendable {
    public var apiBase: URL
    public var authBase: URL
    public var mcpBase: URL

    public init(apiBase: URL, authBase: URL, mcpBase: URL) {
        self.apiBase = apiBase
        self.authBase = authBase
        self.mcpBase = mcpBase
    }

    // TODO: replace with the real production hostnames before first release
    // (open item in docs/PLAN.md).
    public static let production = NAMSConfig(
        apiBase: URL(string: "https://api.nams.neo4jlabs.com")!,
        authBase: URL(string: "https://api.nams.neo4jlabs.com")!,
        mcpBase: URL(string: "https://mcp.nams.neo4jlabs.com")!
    )

    /// The `make dev-all` stack from the project-gaylord monorepo.
    public static let localDev = NAMSConfig(
        apiBase: URL(string: "http://localhost:8080")!,
        authBase: URL(string: "http://localhost:8081")!,
        mcpBase: URL(string: "http://localhost:9090")!
    )

    public static func resolved(defaults: UserDefaults = .standard) -> NAMSConfig {
        var config = NAMSConfig.production
        if let s = defaults.string(forKey: "NAMSAPIBaseURL"), let url = URL(string: s) {
            config.apiBase = url
        }
        if let s = defaults.string(forKey: "NAMSAuthBaseURL"), let url = URL(string: s) {
            config.authBase = url
        }
        if let s = defaults.string(forKey: "NAMSMCPBaseURL"), let url = URL(string: s) {
            config.mcpBase = url
        }
        return config
    }
}
