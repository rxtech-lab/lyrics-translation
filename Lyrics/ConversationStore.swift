import Foundation
import RxAgentSDK

/// Saves each document's chat with the chat agent under Application Support so it continues next time.
@MainActor enum ConversationStore {
    private struct Saved: Codable {
        var threadID: UUID
        var messages: [Message]
        var sessions: [String: String]
        var summary: String
        var compacted: Set<UUID>
    }
    private struct Message: Codable {
        var id: UUID
        var role: AgentRole
        var timestamp: Date
        var error: String?
        var blocks: [Block]
    }
    private struct Block: Codable {
        enum Kind: String, Codable { case text, thinking, tool }
        var kind: Kind
        var id: String
        var text: String?
        var toolName: String?
        var toolInput: [String: JSONValue]?
        var toolResult: String?
        var toolError: Bool?
    }

    private static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "LyricStudio/Conversations", directoryHint: .isDirectory)
    }
    private static func file(_ id: UUID) -> URL { directory.appending(path: "\(id.uuidString).json") }

    static func save(_ thread: AgentThread, for id: UUID) {
        guard !thread.messages.isEmpty else { delete(id); return }
        let messages = thread.messages.map { message in
            Message(id: message.id, role: message.role, timestamp: message.timestamp, error: message.error, blocks: message.blocks.map { block in
                switch block {
                case .text(let id, let text): Block(kind: .text, id: id.uuidString, text: text)
                case .thinking(let id, let text): Block(kind: .thinking, id: id.uuidString, text: text)
                case .toolCall(let call): Block(kind: .tool, id: call.id, toolName: call.name, toolInput: call.input,
                                                toolResult: call.result ?? "", toolError: call.isError)
                }
            })
        }
        let saved = Saved(threadID: thread.id.rawValue, messages: messages,
                          sessions: Dictionary(uniqueKeysWithValues: thread.nativeSessionIDs.map { ($0.key.rawValue, $0.value) }),
                          summary: thread.summary, compacted: thread.compactedMessageIDs)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(saved).write(to: file(id), options: .atomic)
        } catch {
            print("Could not save conversation: \(error)")
        }
    }

    /// The saved conversation, or `nil` when there is none.
    static func load(_ id: UUID) -> AgentThread? {
        guard let data = try? Data(contentsOf: file(id)),
              let saved = try? JSONDecoder().decode(Saved.self, from: data), !saved.messages.isEmpty else { return nil }
        let thread = AgentThread(id: AgentThreadID(saved.threadID))
        thread.load(
            messages: saved.messages.map { message in
                AgentMessage(id: message.id, role: message.role, blocks: message.blocks.map { block in
                    switch block.kind {
                    case .text: .text(id: UUID(uuidString: block.id) ?? UUID(), block.text ?? "")
                    case .thinking: .thinking(id: UUID(uuidString: block.id) ?? UUID(), block.text ?? "")
                    case .tool: .toolCall(AgentToolCall(id: block.id, name: block.toolName ?? "", input: block.toolInput ?? [:],
                                                        result: block.toolResult ?? "", isError: block.toolError ?? false, hasCompleteInput: true))
                    }
                }, timestamp: message.timestamp, error: message.error)
            },
            nativeSessionIDs: Dictionary(uniqueKeysWithValues: saved.sessions.map { (AgentClientID($0.key), $0.value) }),
            summary: saved.summary,
            compactedMessageIDs: saved.compacted)
        return thread
    }

    static func delete(_ id: UUID) { try? FileManager.default.removeItem(at: file(id)) }
}
