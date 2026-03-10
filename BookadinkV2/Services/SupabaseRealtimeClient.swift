import Foundation

final class SupabaseClubChatRealtimeClient {
    enum Event {
        case connected
        case postgresChange
        case error(String)
        case disconnected
    }

    private let session: URLSession
    private let clubID: UUID
    private let accessTokenProvider: () -> String?
    private let includeModerationMessages: Bool
    private let onEvent: @MainActor (Event) -> Void

    private var socketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var referenceCounter: Int = 1
    private var isStopping = false

    init(
        session: URLSession = .shared,
        clubID: UUID,
        includeModerationMessages: Bool,
        accessTokenProvider: @escaping () -> String?,
        onEvent: @escaping @MainActor (Event) -> Void
    ) {
        self.session = session
        self.clubID = clubID
        self.includeModerationMessages = includeModerationMessages
        self.accessTokenProvider = accessTokenProvider
        self.onEvent = onEvent
    }

    func start() {
        guard socketTask == nil else { return }
        isStopping = false

        guard let url = Self.makeRealtimeURL() else {
            Task { @MainActor in
                onEvent(.error("Realtime URL is invalid."))
            }
            return
        }

        let task = session.webSocketTask(with: url)
        socketTask = task
        task.resume()

        receiveTask = Task { [weak self] in
            guard let self else { return }
            await self.sendJoin()
            await self.onEvent(.connected)
            await self.receiveLoop()
        }

        heartbeatTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                if Task.isCancelled { break }
                await self.sendHeartbeat()
            }
        }
    }

    func stop() {
        isStopping = true
        reconnectTask?.cancel()
        reconnectTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        socketTask?.cancel(with: .normalClosure, reason: nil)
        socketTask = nil
        Task { @MainActor in
            onEvent(.disconnected)
        }
    }

    @MainActor
    private func receiveLoop() async {
        guard let socketTask else { return }

        while !Task.isCancelled {
            do {
                let message = try await socketTask.receive()
                switch message {
                case let .string(text):
                    await handleIncoming(text: text)
                case let .data(data):
                    if let text = String(data: data, encoding: .utf8) {
                        await handleIncoming(text: text)
                    }
                @unknown default:
                    break
                }
            } catch {
                if isStopping { return }
                onEvent(.error(error.localizedDescription))
                await scheduleReconnect()
                return
            }
        }
    }

    @MainActor
    private func handleIncoming(text: String) async {
        guard
            let data = text.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return
        }

        let event = (json["event"] as? String) ?? ""
        let topic = (json["topic"] as? String) ?? ""

        if event == "postgres_changes" {
            onEvent(.postgresChange)
            return
        }

        if event == "phx_reply", topic.hasPrefix("realtime:club-chat-") {
            if
                let payload = json["payload"] as? [String: Any],
                let status = payload["status"] as? String,
                status.lowercased() == "error"
            {
                onEvent(.error("Realtime subscription failed."))
            }
        }
    }

    @MainActor
    private func scheduleReconnect() async {
        guard !isStopping else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if Task.isCancelled || self.isStopping { return }
            self.stop()
            self.start()
        }
    }

    @MainActor
    private func sendJoin() async {
        let topic = "realtime:club-chat-\(clubID.uuidString.lowercased())"
        let postgresChanges = makePostgresChangesConfig()
        let payload: [String: Any] = [
            "config": [
                "broadcast": ["self": false],
                "presence": ["key": ""],
                "postgres_changes": postgresChanges
            ],
            "access_token": (accessTokenProvider()?.isEmpty == false) ? accessTokenProvider()! : SupabaseConfig.anonKey
        ]
        await sendPhoenixMessage(topic: topic, event: "phx_join", payload: payload)
    }

    @MainActor
    private func sendHeartbeat() async {
        await sendPhoenixMessage(topic: "phoenix", event: "heartbeat", payload: [:])
    }

    @MainActor
    private func sendPhoenixMessage(topic: String, event: String, payload: [String: Any]) async {
        guard let socketTask else { return }

        let ref = nextRef()
        let envelope: [String: Any] = [
            "topic": topic,
            "event": event,
            "payload": payload,
            "ref": ref
        ]
        guard
            let data = try? JSONSerialization.data(withJSONObject: envelope),
            let text = String(data: data, encoding: .utf8)
        else { return }

        do {
            try await socketTask.send(.string(text))
        } catch {
            onEvent(.error(error.localizedDescription))
        }
    }

    private func nextRef() -> String {
        defer { referenceCounter += 1 }
        return String(referenceCounter)
    }

    private func makePostgresChangesConfig() -> [[String: String]] {
        var changes: [[String: String]] = [
            [
                "event": "*",
                "schema": "public",
                "table": "feed_posts",
                "filter": "club_id=eq.\(clubID.uuidString.lowercased())"
            ],
            [
                "event": "*",
                "schema": "public",
                "table": "feed_comments"
            ],
            [
                "event": "*",
                "schema": "public",
                "table": "feed_reactions"
            ]
        ]
        if includeModerationMessages {
            changes.append([
                "event": "*",
                "schema": "public",
                "table": "club_messages",
                "filter": "club_id=eq.\(clubID.uuidString.lowercased())"
            ])
        }
        return changes
    }

    private static func makeRealtimeURL() -> URL? {
        guard let baseURL = URL(string: SupabaseConfig.urlString) else { return nil }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = (components.scheme == "https") ? "wss" : "ws"
        components.path = "/realtime/v1/websocket"
        components.queryItems = [
            URLQueryItem(name: "apikey", value: SupabaseConfig.anonKey),
            URLQueryItem(name: "vsn", value: "1.0.0")
        ]
        return components.url
    }
}
