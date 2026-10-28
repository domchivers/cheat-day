// Hand a TestFlight build to the family: wait for Apple to finish processing it, set its "What to Test" note
// from native/WhatsNew.txt, add it to the "External Testers" group and submit it for beta review.
//   swift tools/TestFlightExternal.swift <build number>
// Called by mac-testflight.sh after the upload. Needs an App Store Connect API key (App Manager), made by the
// owner in App Store Connect → Users and Access → Integrations, with these set in ~/.zshrc:
//   ASC_KEY_ID, ASC_ISSUER_ID, and the .p8 at ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8
// (or ASC_KEY_PATH). The key's contents are never printed.
import Foundation
import CryptoKit

let bundleID = "com.cheatdays.app"
let groupName = "External Testers"
let locale = "en-GB"

func fail(_ s: String) -> Never { FileHandle.standardError.write(("TestFlightExternal: " + s + "\n").data(using: .utf8)!); exit(1) }

let env = ProcessInfo.processInfo.environment
guard CommandLine.arguments.count > 1 else { fail("usage: swift tools/TestFlightExternal.swift <build number>") }
let buildNumber = CommandLine.arguments[1]
guard let keyID = env["ASC_KEY_ID"], let issuer = env["ASC_ISSUER_ID"] else { fail("ASC_KEY_ID and ASC_ISSUER_ID aren't set") }
let keyPath = env["ASC_KEY_PATH"] ?? (NSHomeDirectory() + "/.appstoreconnect/private_keys/AuthKey_\(keyID).p8")
guard let pem = try? String(contentsOfFile: keyPath, encoding: .utf8) else { fail("no API key at \(keyPath)") }
guard let key = try? P256.Signing.PrivateKey(pemRepresentation: pem) else { fail("couldn't read the API key at \(keyPath)") }

let here = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let whatsNew = (try? String(contentsOf: here.appendingPathComponent("../native/WhatsNew.txt"), encoding: .utf8))?
    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

func b64url(_ d: Data) -> String {
    d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

// a fresh token for each call: they only last 20 minutes and processing can take longer
func token() -> String {
    let now = Int(Date().timeIntervalSince1970)
    let head = b64url(try! JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": keyID, "typ": "JWT"]))
    let body = b64url(try! JSONSerialization.data(withJSONObject: ["iss": issuer, "iat": now, "exp": now + 1100, "aud": "appstoreconnect-v1"]))
    let sig = try! key.signature(for: Data((head + "." + body).utf8))
    return head + "." + body + "." + b64url(sig.rawRepresentation)
}

typealias JSON = [String: Any]

func call(_ method: String, _ path: String, _ body: JSON? = nil) async -> (Int, JSON) {
    var req = URLRequest(url: URL(string: "https://api.appstoreconnect.apple.com" + path)!)
    req.httpMethod = method
    req.setValue("Bearer " + token(), forHTTPHeaderField: "Authorization")
    if let body {
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try! JSONSerialization.data(withJSONObject: body)
    }
    guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return (0, [:]) }
    let json = (try? JSONSerialization.jsonObject(with: data)) as? JSON ?? [:]
    return ((resp as? HTTPURLResponse)?.statusCode ?? 0, json)
}

func first(_ j: JSON) -> JSON? { (j["data"] as? [JSON])?.first }
func errors(_ j: JSON) -> String { ((j["errors"] as? [JSON]) ?? []).compactMap { $0["detail"] as? String }.joined(separator: "; ") }

let q = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: .alphanumerics)! }

let (_, apps) = await call("GET", "/v1/apps?filter%5BbundleId%5D=\(q(bundleID))")
guard let appID = first(apps)?["id"] as? String else { fail("couldn't find the app \(bundleID): \(errors(apps))") }

// Apple takes a while to process an upload; wait up to 40 minutes for it to turn VALID
var buildID = ""
for attempt in 0..<80 {
    let (_, builds) = await call("GET", "/v1/builds?filter%5Bapp%5D=\(appID)&filter%5Bversion%5D=\(q(buildNumber))")
    if let b = first(builds), let id = b["id"] as? String {
        let state = (b["attributes"] as? JSON)?["processingState"] as? String ?? ""
        if state == "VALID" { buildID = id; break }
        if state == "FAILED" || state == "INVALID" { fail("Apple says build \(buildNumber) is \(state)") }
    }
    if attempt % 4 == 0 { print("Waiting for Apple to process build \(buildNumber)…") }
    try? await Task.sleep(nanoseconds: 30_000_000_000)
}
if buildID.isEmpty { fail("build \(buildNumber) still isn't processed after 40 minutes; run this again later") }

if !whatsNew.isEmpty {
    let (_, locs) = await call("GET", "/v1/builds/\(buildID)/betaBuildLocalizations")
    let existing = (locs["data"] as? [JSON] ?? []).first { (($0["attributes"] as? JSON)?["locale"] as? String) == locale } ?? first(locs)
    let (code, res): (Int, JSON)
    if let id = existing?["id"] as? String {
        (code, res) = await call("PATCH", "/v1/betaBuildLocalizations/\(id)",
            ["data": ["type": "betaBuildLocalizations", "id": id, "attributes": ["whatsNew": whatsNew]]])
    } else {
        (code, res) = await call("POST", "/v1/betaBuildLocalizations",
            ["data": ["type": "betaBuildLocalizations", "attributes": ["locale": locale, "whatsNew": whatsNew],
                      "relationships": ["build": ["data": ["type": "builds", "id": buildID]]]]])
    }
    print(code < 300 ? "What to Test note set." : "Couldn't set the What to Test note: \(errors(res))")
}

let (_, groups) = await call("GET", "/v1/betaGroups?filter%5Bapp%5D=\(appID)&filter%5Bname%5D=\(q(groupName))")
guard let groupID = first(groups)?["id"] as? String else { fail("no tester group called \"\(groupName)\": \(errors(groups))") }
let (addCode, added) = await call("POST", "/v1/betaGroups/\(groupID)/relationships/builds", ["data": [["type": "builds", "id": buildID]]])
if addCode >= 300 { fail("couldn't add the build to \(groupName): \(errors(added))") }
print("Added to \(groupName).")

let (subCode, sub) = await call("POST", "/v1/betaAppReviewSubmissions",
    ["data": ["type": "betaAppReviewSubmissions", "relationships": ["build": ["data": ["type": "builds", "id": buildID]]]]])
if subCode < 300 { print("Submitted for beta review. Testers get it as soon as Apple approves (often minutes for a later build).") }
else if subCode == 409 { print("Already submitted or approved: \(errors(sub))") }
else { fail("couldn't submit for beta review: \(errors(sub))") }
