import Foundation
import SwiftUI

// MARK: - Data Model

struct SavedConnection: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var addr: String
}

// MARK: - ConnectionListStore

@MainActor
final class ConnectionListStore: ObservableObject {
    @Published var connections: [SavedConnection] = []

    private let defaultsKey = "savedConnections"

    /// 初回起動時のシード。自分のサーバーに合わせて書き換えるか、
    /// アプリ内の「+」から追加する（アドレスは <tailscale-ip>:<socat-port>）
    private static let knownServers: [(name: String, addr: String)] = [
        ("example-server", "100.64.0.1:17778"),
    ]

    init() {
        load()
    }

    func load() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([SavedConnection].self, from: data),
           !decoded.isEmpty {
            connections = decoded
        }
        // 既知サーバーの追い付き（このバージョンキーにつき一度だけ実行。
        // 以後ユーザーが削除・編集したものを勝手に復活させない）
        let seedKey = "seededServers.v2"
        if !UserDefaults.standard.bool(forKey: seedKey) {
            for server in Self.knownServers where !connections.contains(where: { $0.name == server.name }) {
                connections.append(SavedConnection(id: UUID(), name: server.name, addr: server.addr))
            }
            UserDefaults.standard.set(true, forKey: seedKey)
            save()
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(connections) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    func add(_ connection: SavedConnection) {
        connections.append(connection)
        save()
    }

    func update(_ connection: SavedConnection) {
        if let idx = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[idx] = connection
            save()
        }
    }

    func delete(at offsets: IndexSet) {
        connections.remove(atOffsets: offsets)
        save()
    }
}
