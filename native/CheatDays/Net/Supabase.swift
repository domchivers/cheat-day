import Foundation
import Observation
import Security

struct AuthUser: Codable { var id: String; var email: String? }
struct AuthSession: Codable { var access_token: String; var refresh_token: String; var user: AuthUser }

struct APIError: LocalizedError {
    var status: Int
    var message: String
    var errorDescription: String? { message }
}

/// Sign-in and the REST calls, against the same Supabase project as the website (one account for both).
@MainActor @Observable
final class Supabase {
    static let shared = Supabase()
    private(set) var session: AuthSession?

    private init() {
        if let d = Keychain.load("session") { session = try? JSONDecoder().decode(AuthSession.self, from: d) }
    }

    var userId: String? { session?.user.id }
    var email: String { session?.user.email ?? "" }

    func signIn(email: String, password: String) async throws {
        let d = try await token(grant: "password", body: ["email": email, "password": password])
        try keep(d)
        // a second, separate session for the web screens inside the app, so the two never fight over one refresh token
        if let web = try? await token(grant: "password", body: ["email": email, "password": password]) { Keychain.save("webSession", web) }
    }

    /// True when signed in straight away; false when Supabase wants the email confirmed first.
    func signUp(email: String, password: String) async throws -> Bool {
        let (d, r) = try await send("/auth/v1/signup", method: "POST", body: ["email": email, "password": password], auth: false)
        guard (200..<300).contains(r.statusCode) else { throw Self.error(d, r.statusCode, "Couldn't create the account") }
        if let j = try? JSONSerialization.jsonObject(with: d) as? JSON, j["access_token"] != nil { try keep(d); Keychain.save("webSession", d); return true }
        return false
    }

    func signOut() {
        session = nil
        Keychain.delete("session"); Keychain.delete("webSession")
    }

    // MARK: data

    /// The whole synced record, or nil when this account has never saved one.
    func pullDoc() async throws -> JSON? {
        guard let id = userId else { return nil }
        let d = try await rest("/rest/v1/cheatday?user_id=eq.\(id)&select=data,updated_at")
        let rows = (try JSONSerialization.jsonObject(with: d) as? [JSON]) ?? []
        return rows.first.flatMap { $0["data"] as? JSON }
    }

    func pushDoc(_ data: JSON) async throws {
        guard let id = userId else { return }
        _ = try await rest("/rest/v1/cheatday", method: "POST", body: [["user_id": id, "data": data, "updated_at": ISO.now()] as JSON], prefer: "resolution=merge-duplicates")
    }

    /// Today's summary for friends (the web app's publishDay).
    func publishDay(_ day: JSON) async throws {
        guard let id = userId else { return }
        var row = day; row["user_id"] = id; row["updated_at"] = ISO.now()
        _ = try await rest("/rest/v1/days", method: "POST", body: [row], prefer: "resolution=merge-duplicates")
    }

    // MARK: plumbing

    func rest(_ path: String, method: String = "GET", body: Any? = nil, prefer: String? = nil) async throws -> Data {
        var (d, r) = try await send(path, method: method, body: body, prefer: prefer)
        if r.statusCode == 401, await refresh() { (d, r) = try await send(path, method: method, body: body, prefer: prefer) }
        guard (200..<300).contains(r.statusCode) else { throw Self.error(d, r.statusCode, "Cloud request failed (\(r.statusCode))") }
        return d
    }

    /// Access tokens last about an hour. Only a definite rejection of the refresh token signs you out, never a network blip.
    private func refresh() async -> Bool {
        guard let rt = session?.refresh_token else { return false }
        do { try keep(try await token(grant: "refresh_token", body: ["refresh_token": rt])); return true }
        catch let e as APIError where e.status == 400 || e.status == 401 { signOut(); return false }
        catch { return false }
    }

    private func token(grant: String, body: JSON) async throws -> Data {
        let (d, r) = try await send("/auth/v1/token?grant_type=\(grant)", method: "POST", body: body, auth: false)
        guard (200..<300).contains(r.statusCode) else { throw Self.error(d, r.statusCode, "Sign-in failed") }
        return d
    }

    private func keep(_ d: Data) throws {
        session = try JSONDecoder().decode(AuthSession.self, from: d)
        Keychain.save("session", d)
    }

    private func send(_ path: String, method: String, body: Any? = nil, prefer: String? = nil, auth: Bool = true) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: SupabaseConfig.url.absoluteString + path) else { throw APIError(status: 0, message: "Bad address") }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = method
        req.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let prefer { req.setValue(prefer, forHTTPHeaderField: "Prefer") }
        if auth, let t = session?.access_token { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (d, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError(status: 0, message: "No answer from the server") }
        return (d, http)
    }

    private static func error(_ d: Data, _ status: Int, _ fallback: String) -> APIError {
        let j = (try? JSONSerialization.jsonObject(with: d) as? JSON) ?? [:]
        let m = [j["error_description"], j["msg"], j["message"], j["error"]].compactMap { $0 as? String }.first ?? fallback
        return APIError(status: status, message: m)
    }
}

/// The session lives in the Keychain, not in a file.
enum Keychain {
    private static let service = "cheatdays"
    static func save(_ key: String, _ data: Data) {
        delete(key)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key,
                                kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        SecItemAdd(q as CFDictionary, nil)
    }
    static func load(_ key: String) -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }
    static func delete(_ key: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
    }
}
