//
//  GoldLifeAPI.swift — My Business's only Gold Life ID network surface.
//
//  Talks exclusively to gl-money-api (the shared Gold Life Worker). My Business
//  is a soft-gated, CloudKit-backed app, so this client is deliberately tiny:
//  it learns the caller's canonical Gold Life ID (`/me`) and records which
//  CloudKit user this account maps to (`/app-link`) so a future backend
//  migration can claim the existing data.
//
//  It also carries the account-deletion surface, because the identity Worker is
//  the only one that can answer "which Gold Life apps has this person used"
//  (`/account/apps`). My Business's own records live on
//  gl-business-api and go through GLSyncTransport.
//
//  Every request carries the caller's Gold Life ID session JWT as a Bearer
//  token; the Worker verifies it and serves only that user's identity. The app
//  itself holds no API credential — there is nothing in the binary that could be
//  extracted and replayed against someone else's account.
//
//  Mirrors the shared stale-token dance so the same debugged
//  behavior applies here.
//

import Foundation
import StytchCore
import GoldLifeUI
import GoldLifeCloud

enum GoldLifeAPIError: Error {
    case badStatus(Int)
    /// No Gold Life ID session — the caller must sign in first. Distinct from a
    /// 401, which means the session went stale in flight.
    case notSignedIn
}

struct GoldLifeAPI {
    static let shared = GoldLifeAPI()

    /// Fired only when the session is over by Stytch's own verdict: GoldLifeCloud's one
    /// refresh found Stytch refused it (`.sessionExpired`), or the SDK holds no session
    /// (`.notSignedIn`). Weak signal never fires it: a refresh that can't reach Stytch, or a
    /// fresh token the Worker still refuses, is a "try again" error that keeps the session
    /// (law 13, owner ruling 2026-09-28).
    @MainActor static var onSessionExpired: (@MainActor () async -> Void)?

    /// The request `send` dispatches — built in one place so its shape is testable without a
    /// network. A query string goes in `queryItems`, NEVER in `path`: the transport treats the
    /// path as a path, so a `?` in it was percent-encoded to `%3F` and the Worker answered 404
    /// (the build-79 `/entitlement%3Fapp=my_business` regression that hid every comp).
    nonisolated static func request(_ path: String,
                                    method: String = "GET",
                                    queryItems: [URLQueryItem] = [],
                                    body: Data? = nil) -> GLCloudRequest {
        var headers: [String: String] = [:]
        if body != nil { headers["Content-Type"] = "application/json" }
        return GLCloudRequest(
            target: .custom(LocalSecrets.workerURL),
            path: path,
            method: method,
            queryItems: queryItems,
            headers: headers,
            body: body,
            authMode: .sessionJwt
        )
    }

    /// `GET /entitlement?app=<app>` — the app goes in a query item, never in the path.
    nonisolated static func entitlementRequest(app: String) -> GLCloudRequest {
        request("entitlement", queryItems: [URLQueryItem(name: "app", value: app)])
    }

    /// Routes every call through canonical `GLCloudTransport.dispatch`.
    /// Setting a breakpoint in `GLCloudTransport.dispatch` captures all calls.
    nonisolated func send(_ path: String,
                          method: String = "GET",
                          queryItems: [URLQueryItem] = [],
                          body: Data? = nil) async throws -> Data {
        try await send(Self.request(path, method: method, queryItems: queryItems, body: body))
    }

    nonisolated func send(_ req: GLCloudRequest) async throws -> Data {
        do {
            let res = try await GLCloudTransport.shared.dispatch(req)
            return res.data
        } catch let error as GLCloudError {
            switch error {
            case .notSignedIn, .sessionExpired:
                await GoldLifeAPI.onSessionExpired?()
                throw GoldLifeAPIError.notSignedIn
            case .badStatus(let code, _):
                throw GoldLifeAPIError.badStatus(code)
            default:
                throw GoldLifeAPIError.badStatus(0)
            }
        } catch {
            throw GoldLifeAPIError.badStatus(0)
        }
    }

    /// The caller's canonical Gold Life ID — the same id every Gold Life app shows for the
    /// same person, shown here (copyable) in Settings and About for support and
    /// comp lookups. It is an identifier, not a password: it can't be used to
    /// sign in.

    struct MeResponse: Decodable {
        let goldLifeId: String
        let vipAccess: VIPAccess?
        enum CodingKeys: String, CodingKey {
            case goldLifeId = "gold_life_id"
            case vipAccess = "vip_access"
        }
    }

    struct VIPAccess: Decodable {
        let myBusiness: Bool

        enum CodingKeys: String, CodingKey {
            case myBusiness = "my_business"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            myBusiness = try container.decodeIfPresent(Bool.self, forKey: .myBusiness) ?? false
        }
    }

    nonisolated func me() async throws -> MeResponse {
        return try JSONDecoder().decode(MeResponse.self, from: await send("me"))
    }

    nonisolated func fetchEntitlement(app: String = "my_business") async throws -> GLEntitlement {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(GLEntitlement.self, from: await send(Self.entitlementRequest(app: app)))
    }

    /// Record which CloudKit user this Gold Life ID corresponds to, so a future
    /// backend migration can claim the existing My Business data. `externalId` is
    /// the CloudKit userRecordID.recordName — the only stable id the local data
    /// has. Bookkeeping only: the Worker scopes the write to the caller's session,
    /// never the body.
    nonisolated func appLink(externalId: String) async throws {
        let body = try JSONEncoder().encode(["app": "my-business", "external_id": externalId])
        _ = try await send("app-link", method: "POST", body: body)
    }

    /// Erase this Gold Life ID: the Worker deletes the identity and every app
    /// link, everywhere it's shared. Irreversible and deliberately server-side.
    ///
    /// LEVEL TWO of the two-level deletion. The Worker refuses with 409
    /// (`app_data_remains`) while any app still holds anything for this account,
    /// so a `badStatus(409)` here is not a network problem — it means the screen's
    /// picture of "every app is empty" went stale between the check and the tap.
    nonisolated func deleteAccount() async throws {
        _ = try await send("account/delete", method: "POST")
    }

    // MARK: - The account-deletion inventory

    /// Every Gold Life app this account has ever signed into, one row each.
    ///
    /// `name` and `apiBase` are nil for an app this Worker's registry cannot name.
    /// The server returns those rows rather than hiding them, deliberately: telling
    /// someone their data is gone because we had not heard of the app holding it is
    /// the worst thing a deletion screen can say. `appId` is CLIENT-WRITTEN text
    /// (any app may POST /app-link with up to 64 characters of anything), so it is
    /// an identifier and never something to render as if it were a name.
    struct AppLink: Decodable {
        let appId: String
        let name: String?
        let apiBase: String?

        enum CodingKeys: String, CodingKey {
            case appId = "app_id"
            case name
            case apiBase = "api_base"
        }
    }

    nonisolated func apps() async throws -> [AppLink] {
        struct Wrapper: Decodable { let apps: [AppLink] }
        return try JSONDecoder().decode(Wrapper.self, from: await send("account/apps")).apps
    }
}
