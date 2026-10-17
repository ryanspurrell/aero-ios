import Foundation

/// Turns what was typed into an address, and checks that it answers.
enum AddressChecker {
    /// Each case carries the sentence shown to the person.
    enum Problem: Error {
        case empty, notHTTPS, invalid, notFound, notAero, unreachable, certificate, serverError

        var message: String {
            switch self {
            case .empty, .invalid:
                return "That doesn't look like an address. Check it and try again."
            case .notHTTPS:
                return "Plain http addresses aren't supported. Use an address that starts with https."
            case .notFound:
                return "Couldn't find that server. Check the address and try again."
            case .unreachable:
                return "Couldn't reach that server. Check that it's on and try again."
            case .certificate:
                return "That server's certificate isn't trusted. Check the address and try again."
            case .serverError:
                return "The server answered with an error. Try again later."
            case .notAero:
                return "That server answered, but Aero isn't at that address. Check the whole address, including anything after the slash."
            }
        }
    }

    /// Accepts a host with or without https://, adds https:// when missing,
    /// and refuses http://.
    static func normalize(_ typed: String) -> Result<URL, Problem> {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .failure(.empty) }
        if text.lowercased().hasPrefix("http://") { return .failure(.notHTTPS) }
        if !text.contains("://") { text = "https://" + text }
        guard text.lowercased().hasPrefix("https://"),
              let components = URLComponents(string: text),
              let host = components.host, host.contains("."),
              let url = components.url else {
            return .failure(.invalid)
        }
        return .success(url)
    }

    /// Asks the server for the address. Any answer below 500 counts as
    /// answering, including a redirect to a sign-in page, which is followed.
    static func check(_ url: URL) async -> Problem? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.httpMethod = "GET"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 404 {
                // a server that answers "not found" at the address has no Aero there (a Tailscale address without /resident, 2026-10-17)
                return .notAero
            }
            if let http = response as? HTTPURLResponse, http.statusCode >= 500 {
                return .serverError
            }
            return nil
        } catch {
            switch (error as? URLError)?.code {
            case .cannotFindHost, .dnsLookupFailed:
                return .notFound
            case .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
                 .secureConnectionFailed, .clientCertificateRejected:
                return .certificate
            default:
                return .unreachable
            }
        }
    }
}
