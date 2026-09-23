import Foundation
import UserNotifications

/// Supabase Realtime → iPhone notifications. Subscribes to row changes on every table the user can read,
/// as that user (so RLS still applies), and turns each insert or update into a notification.
/// This is the no-server version; for alerts while the app is closed, a Supabase Edge Function
/// on a database webhook would send the same message through APNs.
final class LiveUpdates: NSObject, UNUserNotificationCenterDelegate {
    static let shared = LiveUpdates()

    private var socket: URLSessionWebSocketTask?
    private var heartbeat: Task<Void, Never>?
    private var ref = 0
    private(set) var connectedTables: [String] = []

    func start() async {
        let app = SupabaseApp.shared
        guard app.isAdmin || app.session != nil, !app.tables.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        stop()

        guard let host = URL(string: app.url)?.host,
              let url = URL(string: "wss://\(host)/realtime/v1/websocket?apikey=\((app.isAdmin ? app.adminKey : app.key).queryEncoded)&vsn=1.0.0") else { return }
        let task = URLSession.shared.webSocketTask(with: url)
        socket = task
        task.resume()

        let token = (try? await app.headers())?["Authorization"]?.replacingOccurrences(of: "Bearer ", with: "")
        connectedTables = app.tables.map(\.name)
        for t in connectedTables {
            var payload: [String: Any] = ["config": ["postgres_changes": [["event": "*", "schema": "public", "table": t]]]]
            if let token { payload["access_token"] = token }
            send(["topic": "realtime:opendesk-\(t)", "event": "phx_join", "payload": payload, "ref": nextRef()])
        }
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                self?.send(["topic": "phoenix", "event": "heartbeat", "payload": [:], "ref": self?.nextRef() ?? "0"])
            }
        }
        receive()
    }

    func stop() {
        heartbeat?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func nextRef() -> String { ref += 1; return String(ref) }

    private func send(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: d, encoding: .utf8) else { return }
        socket?.send(.string(s)) { _ in }
    }

    private func receive() {
        socket?.receive { [weak self] result in
            guard let self else { return }
            if case .success(.string(let text)) = result { self.handle(text) }
            if case .failure = result { return }
            self.receive()
        }
    }

    private func handle(_ text: String) {
        guard let d = text.data(using: .utf8), let j = try? JSONDecoder().decode(JSONValue.self, from: d),
              j["event"]?.string == "postgres_changes", let data = j["payload"]?["data"] else { return }
        let type = data["type"]?.string ?? ""
        let table = data["table"]?.string ?? "table"
        let record = data["record"] ?? .null
        guard type == "INSERT" || type == "UPDATE" else { return }

        let sb = SupabaseApp.shared.tables.first { $0.name == table }
        let primary = sb?.nocoColumns.first(where: \.isPrimary)?.title
        let name = primary.flatMap { record[$0]?.display } ?? "A record"
        let pretty = table.replacingOccurrences(of: "_", with: " ").capitalized.singular

        var body = ""
        if type == "UPDATE", let old = data["old_record"] {
            // Report the most interesting change: a status/stage move beats anything else.
            let changed = record.object.keys.filter { k in !["updated_at", "id"].contains(k) && old[k] != nil && old[k] != record[k] }
            if let k = changed.first(where: { ["stage", "status", "state"].contains($0) }) ?? changed.first {
                body = "\(k.replacingOccurrences(of: "_", with: " ").capitalized): \(old[k]?.display ?? "") → \(record[k]?.display ?? "")"
            } else { body = "Updated" }
        } else {
            body = ["event_date", "date", "guests", "budget", "stage", "status"].compactMap { k in
                record[k].flatMap { $0.isNull ? nil : "\(k.replacingOccurrences(of: "_", with: " ").capitalized) \($0.display)" }
            }.prefix(3).joined(separator: " · ")
        }

        let content = UNMutableNotificationContent()
        content.title = type == "INSERT" ? "New \(pretty): \(name)" : "\(name) updated"
        content.body = body
        content.sound = .default
        content.userInfo = ["url": "opendesk://tables"]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // Show banners even while the app is open, which is how a live demo is watched.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}
