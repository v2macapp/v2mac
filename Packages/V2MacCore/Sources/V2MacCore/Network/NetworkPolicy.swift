import Foundation

/// Spec 11, F17: the routes V2Mac's own downloads (app and core updates, Geo files, the sandbox)
/// may take. With `strict` (the kill switch is on) they go only through the connection, never
/// direct; with no connection that means nothing is sent. Turning the kill switch off is the
/// explicit choice for direct.
public enum NetworkPolicy {
    public static func routes(proxyPort: Int?, strict: Bool) -> [FetchRoute] {
        (proxyPort.map { [FetchRoute.localProxy(port: $0)] } ?? []) + (strict ? [] : [.direct])
    }

    public static var noRouteMessage: String {
        String(localized: "Connect first: with the kill switch on, V2Mac downloads only through the connection.")
    }
}
