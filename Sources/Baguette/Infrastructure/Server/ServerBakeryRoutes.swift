import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import NIOCore

/// The browser half of plugin distribution — preview a bakery, then
/// install from it — in its own file like `ServerPluginRoutes`.
///
/// These routes clone repos and write files, so they are as powerful as
/// `boot`/`shutdown` and ride the **same** browser-trust gate
/// (`rejectUntrustedBrowser` — Origin / `Sec-Fetch-Site` / DNS-rebind).
/// On top of that, install demands an explicit `accept` from the modal:
/// preview is safe to call, install is the consented act.
extension Server {

    func bakeryInstaller() -> BakeryInstall {
        return BakeryInstall(checkout: GitCheckout(), home: BaguetteHome.url)
    }

    func registerBakeryRoutes(
        on router: Router<BasicWebSocketRequestContext>,
        rejectUntrustedBrowser: @escaping @Sendable (Request) -> Response?
    ) {
        let installer = bakeryInstaller()
        let home = BaguetteHome.url

        // Clone + read the menu so the modal can show what it'd be
        // trusting. Records nothing.
        router.post("/bakeries/preview") { r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            let ref = try await Self.stringField(r, "ref")
            switch await Self.previewBakery(reference: ref, install: installer) {
            case .ok(let json): return Self.jsonResponse(json)
            case .failed(let message): return Self.pluginError(message, status: .badRequest)
            }
        }

        // The consented act. Refused without `accept:true`.
        router.post("/bakeries/install") { r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            let body = try await Self.jsonBody(r)
            let ref = body["ref"] as? String ?? ""
            let plugin = body["plugin"] as? String
            let accept = body["accept"] as? Bool ?? false
            switch await Self.installBakery(reference: ref, plugin: plugin, accept: accept, install: installer) {
            case .ok(let json): return Self.jsonResponse(json)
            case .rejected: return Self.pluginError("install requires accept:true", status: .forbidden)
            case .failed(let message): return Self.pluginError(message, status: .badRequest)
            }
        }

        router.get("/bakeries.json") { r, _ in
            if let rejected = rejectUntrustedBrowser(r) { return rejected }
            switch Self.listBakeries(home: home) {
            case .ok(let json): return Self.jsonResponse(json)
            case .failed(let message):
                return Self.pluginError(message, status: .internalServerError)
            }
        }
    }

    // MARK: - listing

    enum BakeryListOutcome: Equatable {
        case ok(String)
        case failed(String)
    }

    /// The trusted bakeries, as the modal renders them.
    ///
    /// A read failure is reported rather than flattened to an empty
    /// list: a corrupt or unreadable `bakeries.json` would otherwise
    /// show in the UI as "no bakeries added", which is exactly what a
    /// fresh install looks like — and the user's next add would write
    /// that emptiness back over whatever was really there.
    ///
    /// A serialization failure is reported too. Falling back to `Data()`
    /// meant a 200 with `Content-Type: application/json` and an empty
    /// body, which throws inside the browser's `JSON.parse` with no way
    /// to tell it apart from success.
    static func listBakeries(home: URL) -> BakeryListOutcome {
        do {
            let bakeries = try FileSystemBakeries(home: home).bakeries()
            let dict: [String: Any] = ["bakeries": bakeries.map {
                ["id": $0.id, "commit": $0.commit, "plugins": $0.plugins]
            }]
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
            return .ok(String(decoding: data, as: UTF8.self))
        } catch {
            return .failed("can't read the bakery registry: \(error)")
        }
    }

    // MARK: - preview

    enum BakeryPreviewOutcome: Equatable {
        case ok(String)
        case failed(String)
    }

    static func previewBakery(reference: String, install: BakeryInstall) async -> BakeryPreviewOutcome {
        do {
            let ref = try BakeryRef.parse(reference)
            let preview = try await install.preview(ref)
            var dict: [String: Any] = [
                "commit": preview.commit,
                "alreadyTrusted": preview.alreadyTrusted,
                "url": ref.cloneURL,
                "plugins": preview.menu.entries.map { ["name": $0.name, "path": $0.path] },
            ]
            if let name = preview.menu.name { dict["name"] = name }
            if let description = preview.menu.description { dict["description"] = description }
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
            return .ok(String(decoding: data, as: UTF8.self))
        } catch {
            return .failed(String(describing: error))
        }
    }

    // MARK: - install

    enum BakeryInstallOutcome: Equatable {
        case ok(String)
        /// Consent wasn't given — the modal's Install click sets
        /// `accept:true`; anything else is refused.
        case rejected
        case failed(String)
    }

    static func installBakery(
        reference: String, plugin: String?, accept: Bool, install: BakeryInstall
    ) async -> BakeryInstallOutcome {
        guard accept else { return .rejected }
        do {
            let ref = try BakeryRef.parse(reference)
            let installed = try await install.install(ref: ref, requested: plugin ?? ref.plugin)
            let dict: [String: Any] = ["ok": true, "installed": installed.map {
                ["name": $0.name, "bakery": $0.bakery, "commit": $0.commit]
            }]
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
            return .ok(String(decoding: data, as: UTF8.self))
        } catch {
            return .failed(String(describing: error))
        }
    }

    // MARK: - small shared helpers

    static func jsonResponse(_ json: String) -> Response {
        Response(
            status: .ok,
            headers: [.contentType: "application/json", .cacheControl: "no-cache"],
            body: .init(byteBuffer: ByteBuffer(string: json))
        )
    }

    private static func jsonBody(_ request: Request) async throws -> [String: Any] {
        let buffer = try? await request.body.collect(upTo: 64 * 1024)
        let data = buffer.map { Data(buffer: $0) } ?? Data()
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private static func stringField(_ request: Request, _ key: String) async throws -> String {
        (try await jsonBody(request))[key] as? String ?? ""
    }
}
