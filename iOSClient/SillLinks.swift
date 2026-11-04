// Modified for DUO你电脑, 2026. See NOTICE for upstream attribution.
import Foundation

/// Public links supplied by this distribution's release build.
enum SillLinks {
    /// Omitted in local builds until a public repository is configured.
    static let repository = repositoryURL(Bundle.main.object(forInfoDictionaryKey: "DUORepositoryURL") as? String)
    static let download = repository?.appending(path: "releases")
    static let support = repository?.appending(path: "issues")
    static let privacy = repository?.appending(path: "blob/HEAD/docs/PRIVACY.md")

    static func repositoryURL(_ text: String?) -> URL? {
        guard let text, let components = URLComponents(string: text),
              components.scheme == "https", components.host?.lowercased() == "github.com",
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil,
              components.percentEncodedPath.range(of: "^/[A-Za-z0-9-]+/[A-Za-z0-9_.-]+/?$", options: .regularExpression) != nil
        else { return nil }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let canonicalPath = path.hasSuffix(".git") ? String(path.dropLast(4)) : path
        guard let name = canonicalPath.split(separator: "/").last,
              name != ".", name != "..", canonicalPath.split(separator: "/").count == 2 else { return nil }
        return URL(string: "https://github.com/\(canonicalPath)")
    }

    /// Filled only after this distribution has its own App Store listing.
    static let appStoreText = ""

    /// An https URL from `appStoreText`, else nil. DEBUG: `-SillAppStoreURL <url>` replaces it.
    static var appStore: URL? {
        #if DEBUG
        if let override = UserDefaults.standard.string(forKey: "SillAppStoreURL"), let url = https(override) { return url }
        #endif
        return https(appStoreText)
    }

    private static func https(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme == "https", let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}
