import Foundation

/// What the phone's Organizer asks of the embedded Python: a name and arguments in, the answer out. The real one runs the reader in the
/// app (`EmbeddedReader`); tests give a stand-in.
protocol ReaderRunning {
    func call(_ name: String, _ args: [String: JSONValue]) async throws -> JSONValue
}

enum ReaderFailure: LocalizedError {
    case said(String)
    var errorDescription: String? {
        switch self {
        case .said(let words): return "The phone could not read that: \(words)"
        }
    }
}

extension ReaderRunning {
    /// The answer decoded as `T` with Organizer's own key rules.
    func decode<T: Decodable>(_ name: String, _ args: [String: JSONValue], as type: T.Type) async throws -> T {
        let value = try await call(name, args)
        return try OrganizerDecoder.make().decode(T.self, from: try JSONEncoder().encode(value))
    }
}

/// CPython inside the app (Embedded/FingusPython.m), on one serial queue, started on the first call.
final class EmbeddedReader: ReaderRunning {
    static let shared = EmbeddedReader()
    private let queue = DispatchQueue(label: "fingus.reader", qos: .userInitiated)

    func call(_ name: String, _ args: [String: JSONValue]) async throws -> JSONValue {
        let text = String(data: try JSONEncoder().encode(JSONValue.object(args)), encoding: .utf8) ?? "{}"
        let answer: String = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try FingusPython.shared().callName(name, json: text)) }
                catch { continuation.resume(throwing: error) }
            }
        }
        let parsed = try JSONDecoder().decode(JSONValue.self, from: Data(answer.utf8))
        guard case .object(let envelope) = parsed else { throw ReaderFailure.said("an answer in a shape not expected") }
        if case .string(let words)? = envelope["error"] { throw ReaderFailure.said(words) }
        return envelope["ok"] ?? .null
    }

    /// Seconds the first start took, for the size-and-time report.
    var startSeconds: Double { FingusPython.shared().startSeconds }
}
