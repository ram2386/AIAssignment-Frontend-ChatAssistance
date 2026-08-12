//
//  ContentView.swift
//  ChatAssistance
//
//  Created by Ramkrishna on 12/08/26.
//

import Observation
import SwiftUI

struct ContentView: View {
    @State private var viewModel = ChatViewModel()
    @FocusState private var isInputFocused: Bool

    var body: some View {
        @Bindable var viewModel = viewModel

        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(viewModel.messages) { message in
                                ChatBubble(message: message)
                                    .id(message.id)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: viewModel.messages) { _, messages in
                        guard let lastID = messages.last?.id else { return }

                        withAnimation {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
                }

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                }

                ChatInputBar(
                    text: $viewModel.question,
                    isSending: viewModel.isSending,
                    sendAction: {
                        isInputFocused = false
                        Task { await viewModel.sendQuestion() }
                    }
                )
                .focused($isInputFocused)
                .padding()
                .background(.regularMaterial)
            }
            .navigationTitle("Chat Assistance")
        }
    }
}

private struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .assistant {
                bubble
                Spacer(minLength: 48)
            } else {
                Spacer(minLength: 48)
                bubble
            }
        }
    }

    private var bubble: some View {
        messageText
            .font(.body)
            .foregroundColor(message.role == .user ? .white : .primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(message.role == .user ? Color.accentColor : Color.primary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityLabel(message.role == .user ? "You: \(message.text)" : "Assistant: \(message.text)")
    }

    private var messageText: Text {
        guard message.role == .assistant,
              let attributedText = try? AttributedString(markdown: message.text) else {
            return Text(message.text)
        }

        return Text(attributedText)
    }
}

private struct ChatInputBar: View {
    @Binding var text: String
    let isSending: Bool
    let sendAction: () -> Void

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask a question", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .submitLabel(.send)
                .onSubmit {
                    guard canSend else { return }
                    sendAction()
                }

            Button(action: sendAction) {
                Image(systemName: isSending ? "hourglass" : "paperplane.fill")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSend)
            .accessibilityLabel("Send")
            .accessibilityHint("Sends your question to the chat assistant")
        }
    }
}

private struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let role: ChatRole
    var text: String
}

private enum ChatRole {
    case user
    case assistant
}

@MainActor
@Observable
private final class ChatViewModel {
    var question = ""
    var messages: [ChatMessage] = []
    var isSending = false
    var errorMessage: String?

    private let endpoint = URL(string: "http://127.0.0.1:8000/chat/stream")!

    func sendQuestion() async {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty, !isSending else { return }

        question = ""
        errorMessage = nil
        isSending = true
        messages.append(ChatMessage(role: .user, text: trimmedQuestion))
        messages.append(ChatMessage(role: .assistant, text: ""))

        do {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.httpBody = try JSONEncoder().encode(ChatRequest(question: trimmedQuestion))

            let (bytes, response) = try await URLSession.shared.bytes(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                throw URLError(.badServerResponse)
            }

            for try await line in bytes.lines {
                handleStreamLine(line)
            }
        } catch {
            errorMessage = error.localizedDescription
            replaceEmptyAssistantMessage(with: "Unable to load response.")
        }

        isSending = false
    }

    private func handleStreamLine(_ line: String) {
        guard line.hasPrefix("data:") else { return }

        let data = line
            .dropFirst("data:".count)
            .trimmingCharacters(in: .whitespaces)

        guard !data.isEmpty, data != "[DONE]" else { return }

        guard let text = decodeStreamText(from: data) else { return }

        appendAssistantText(text)
    }

    private func decodeStreamText(from data: String) -> String? {
        guard let jsonData = data.data(using: .utf8),
              let chunk = try? JSONDecoder().decode(ChatStreamChunk.self, from: jsonData) else {
            return nil
        }

        return chunk.text
    }

    private func appendAssistantText(_ text: String) {
        guard let lastIndex = messages.indices.last,
              messages[lastIndex].role == .assistant else { return }

        messages[lastIndex].text += text
    }

    private func replaceEmptyAssistantMessage(with text: String) {
        guard let lastIndex = messages.indices.last,
              messages[lastIndex].role == .assistant,
              messages[lastIndex].text.isEmpty else { return }

        messages[lastIndex].text = text
    }
}

private struct ChatRequest: Encodable {
    let question: String
}

private struct ChatStreamChunk: Decodable {
    let text: String
}

#Preview {
    ContentView()
}
