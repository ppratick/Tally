import Foundation

struct ChatRequest: Codable {
    let conversationID: String
    let requestID: String
    let message: String
    let context: String
}
struct ChatReply: Codable {
    let conversationID: String
    let text: String
    let sources: [BankTransaction]
    let modelCalls: Int
    let inputTokens: Int
    let outputTokens: Int
    let retrievedAt: String
}
struct ChatMessage: Codable, Identifiable {
    let id: String
    let role: String
    let text: String
    var sources: [BankTransaction] = []
    var modelCalls: Int? = nil
    var retrievedAt: String? = nil
}
struct ChatArchive: Codable {
    let serverURL: String
    let conversationID: String
    let messages: [ChatMessage]
    let pending: ChatRequest?
}
