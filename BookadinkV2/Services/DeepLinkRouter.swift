import Foundation

/// Parses incoming URLs into typed deep link destinations.
///
/// Supported schemes:
///   bookadink://club/{uuid}
///   bookadink://game/{uuid}
///
/// Universal links (future, when bookadink.com is live):
///   https://bookadink.com/club/{uuid}
///   https://www.bookadink.com/club/{uuid}
/// Payload of a Supabase email auth callback delivered via deep link.
///
/// Supabase emits the verification link in one of three URL shapes depending on
/// project configuration:
///   - Token-hash (newer default): `?token_hash=<hash>&type=signup` → consume via
///     the `/auth/v1/verify` REST endpoint to obtain a session.
///   - Token grant (legacy implicit / magic-link): tokens in the URL fragment
///     `#access_token=<jwt>&refresh_token=<token>&type=signup` → no extra
///     network call needed; the refresh token is exchanged for a fresh session.
///   - Error: `?error=access_denied&error_description=...` → expired/invalid link;
///     show a recoverable message.
///
/// Both schemes route through `AppState.handleAuthCallback` so the
/// "Verified, continuing…" UX is identical regardless of which Supabase setting
/// the project happens to be on.
enum AuthCallback: Equatable {
    case session(accessToken: String, refreshToken: String)
    case tokenHash(hash: String, type: String)
    case failure(message: String)
}

enum DeepLink: Equatable {
    case club(id: UUID)
    case game(id: UUID)
    case review(gameID: UUID)
    /// Stripe Connect onboarding return. `status` is "complete" or "refresh" (link expired).
    case connectReturn(clubID: UUID, status: String)
    /// Supabase email verification / password recovery return.
    ///
    /// Supabase Dashboard must be configured so that auth redirect URLs include
    /// `bookadink://auth-callback`. Site URL: `bookadink://auth-callback`.
    /// Additional Redirect URLs (one per line) should also list
    /// `bookadink://auth-callback`. Without this config the verification email
    /// will continue to redirect to Supabase's hosted page and the app will
    /// never receive the callback.
    case authCallback(AuthCallback)

    private static let knownHosts: Set<String> = ["bookadink.com", "www.bookadink.com"]

    init?(url: URL) {
        // Auth callback: bookadink://auth-callback?... or bookadink://auth-callback#...
        // Handled FIRST so a malformed/auth URL never falls through to the
        // generic Stripe / club / game path. Both query and fragment params
        // are honoured because Supabase varies between them depending on flow.
        if url.scheme == "bookadink", url.host == "auth-callback" {
            let params = Self.collectParams(from: url)
            if let errorDescription = params["error_description"] ?? params["error"], !errorDescription.isEmpty {
                self = .authCallback(.failure(message: errorDescription.replacingOccurrences(of: "+", with: " ")))
                return
            }
            if let access = params["access_token"], let refresh = params["refresh_token"] {
                self = .authCallback(.session(accessToken: access, refreshToken: refresh))
                return
            }
            if let hash = params["token_hash"], let type = params["type"] {
                self = .authCallback(.tokenHash(hash: hash, type: type))
                return
            }
            // Unknown shape — surface a recoverable error rather than silently dropping.
            self = .authCallback(.failure(message: "Verification link is missing required information."))
            return
        }

        // Stripe Connect return deep links:
        //   bookadink://stripe-return/{clubID}  — owner completed all onboarding steps
        //   bookadink://stripe-refresh/{clubID} — Account Link expired mid-flow
        if url.scheme == "bookadink",
           let host = url.host,
           (host == "stripe-return" || host == "stripe-refresh"),
           let clubID = UUID(uuidString: url.lastPathComponent) {
            let status = host == "stripe-return" ? "complete" : "refresh"
            self = .connectReturn(clubID: clubID, status: status)
            return
        }

        // Custom scheme: bookadink://club/{uuid}
        if url.scheme == "bookadink" {
            guard let host = url.host, let id = UUID(uuidString: url.lastPathComponent) else { return nil }
            switch host {
            case "club": self = .club(id: id)
            case "game": self = .game(id: id)
            default: return nil
            }
            return
        }

        // Universal link: https://bookadink.com/club/{uuid} or https://www.bookadink.com/...
        guard let host = url.host, Self.knownHosts.contains(host) else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count == 2, let id = UUID(uuidString: components[1]) else { return nil }
        switch components[0] {
        case "club": self = .club(id: id)
        case "game": self = .game(id: id)
        default: return nil
        }
    }

    /// Merges query items and fragment-encoded parameters into a single dictionary.
    /// Supabase varies between the two — token-hash flows use query, implicit-grant
    /// flows use fragment. Query wins on conflict because Supabase docs put auth
    /// payload in the query for the modern OTP-verify path.
    private static func collectParams(from url: URL) -> [String: String] {
        var result: [String: String] = [:]
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let items = comps.queryItems {
            for item in items {
                if let value = item.value, !value.isEmpty {
                    result[item.name] = value
                }
            }
        }
        if let fragment = url.fragment, !fragment.isEmpty {
            for pair in fragment.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard kv.count == 2 else { continue }
                let key = kv[0].removingPercentEncoding ?? kv[0]
                let value = kv[1].removingPercentEncoding ?? kv[1]
                if result[key] == nil, !value.isEmpty {
                    result[key] = value
                }
            }
        }
        return result
    }

    /// Shareable URL using the custom scheme so the app opens directly.
    /// Uses bookadink:// rather than HTTPS because bookadink.com is not yet
    /// a live website — HTTPS links just open Safari and hit 404.
    /// Note: `.authCallback` is intentionally not shareable — Supabase emits
    /// the URL itself; we only parse it.
    var shareURL: URL {
        switch self {
        case .club(let id):
            return URL(string: "bookadink://club/\(id.uuidString)")!
        case .game(let id):
            return URL(string: "bookadink://game/\(id.uuidString)")!
        case .review(let gameID):
            return URL(string: "bookadink://game/\(gameID.uuidString)")!
        case .connectReturn(let clubID, let status):
            let host = status == "complete" ? "stripe-return" : "stripe-refresh"
            return URL(string: "bookadink://\(host)/\(clubID.uuidString.lowercased())")!
        case .authCallback:
            // Auth callbacks are inbound-only; share URL is meaningless but the
            // protocol requires a value. Return a sentinel that can never match
            // a real Supabase redirect.
            return URL(string: "bookadink://auth-callback")!
        }
    }

    static func clubURL(id: UUID) -> URL {
        DeepLink.club(id: id).shareURL
    }

    static func gameURL(id: UUID) -> URL {
        DeepLink.game(id: id).shareURL
    }
}
