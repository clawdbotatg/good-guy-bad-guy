import CoreImage
import Foundation
import UIKit

/// Where the cloud classifier lives.
///
/// The token is a soft gate (any secret in a shipped client is extractable) —
/// it stops casual abuse of the free subscription-backed service. It is
/// **never committed**: the build injects it into Info.plist via the
/// `GGBG_CLOUD_TOKEN` build setting (empty by default), e.g.
/// `xcodebuild … GGBG_CLOUD_TOKEN=ggbg_…`. An empty token just means the cloud
/// brain can't reach the service, and the app falls back to local brains.
/// Rotate it in the server's `.env` + the build arg.
enum CloudConfig {
    static let baseURL = URL(string: "https://ggbg.atg.link")!
    static var token: String {
        (Bundle.main.object(forInfoDictionaryKey: "GGBGCloudToken") as? String) ?? ""
    }
}

/// The "Cloud" brain: no download, needs internet. Sends the photo to our
/// classifier service, which identifies it (free, via a Claude subscription on
/// the box) and returns the same good-guy/bad-guy verdict the on-device model
/// would — so the app renders it identically.
///
/// The service is classify-only; text follow-ups need a downloaded local
/// brain, and the reply here says so.
@MainActor
final class CloudEngine: LLMEngine {
    let modelName = "Cloud"

    /// Which model the server should name the organism with. "claude" = the
    /// box's free subscription; a BANKR model id = that vision model via the
    /// gateway. Sent as the `X-Model` header; the server's danger table always
    /// owns the verdict regardless.
    private var serverModel = "claude"

    private struct Classification: Decodable {
        let id: String
        let verdict: String?  // "good" | "bad" | "caution" | null
        let note: String
    }

    enum CloudError: LocalizedError {
        case offline
        case badResponse(Int)
        case unreachable
        var errorDescription: String? {
            switch self {
            case .offline: "You're offline. Pick a local brain in the Brain menu to work without a signal."
            case .badResponse(let code): "The cloud classifier returned an error (\(code))."
            case .unreachable: "Can't reach the cloud classifier. Check your connection, or download a local brain."
            }
        }
    }

    /// For cloud brains, `id` is the server model to name with (e.g. "claude",
    /// "gemini-3.1-pro"). ChatStore passes the selected brain's `serverModel`.
    func setModel(_ id: String) {
        serverModel = id.isEmpty ? "claude" : id
    }
    func reset() {}

    /// "Load" = a reachability probe against /health. No download.
    func load(onProgress: @escaping @MainActor (Double) -> Void) async throws {
        onProgress(0.5)
        var request = URLRequest(url: CloudConfig.baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 10
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw CloudError.unreachable
            }
        } catch {
            throw CloudError.unreachable
        }
        onProgress(1)
    }

    func respond(to prompt: String, image: CIImage?) -> AsyncThrowingStream<String, Error> {
        guard let image else {
            // Follow-up text: the classifier doesn't chat.
            return AsyncThrowingStream<String, Error> { continuation in
                continuation.yield(
                    "Follow-up questions need a downloaded brain — tap Brain above to add one. "
                        + "The cloud gives you the fast good-guy/bad-guy verdict from a photo.")
                continuation.finish()
            }
        }
        return AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    let result = try await self.classify(image)
                    continuation.yield(result)
                    continuation.finish()
                } catch {
                    DebugLog.log("cloud error: \(error)")
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// POST the photo, then compose the exact text the app already renders:
    /// an `ID:` line, then either a `VERDICT:` block or a plain sentence.
    private func classify(_ ciImage: CIImage) async throws -> String {
        guard let jpeg = Self.jpeg(from: ciImage) else {
            throw CloudError.badResponse(0)
        }
        var request = URLRequest(url: CloudConfig.baseURL.appendingPathComponent("classify"))
        request.httpMethod = "POST"
        request.setValue(CloudConfig.token, forHTTPHeaderField: "X-Auth-Token")
        request.setValue(serverModel, forHTTPHeaderField: "X-Model")
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.httpBody = jpeg
        request.timeoutInterval = 120

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw CloudError.unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw CloudError.unreachable }
        guard http.statusCode == 200 else { throw CloudError.badResponse(http.statusCode) }

        let c = try JSONDecoder().decode(Classification.self, from: data)
        let label: String?
        switch c.verdict {
        case "good": label = "GOOD GUY"
        case "bad": label = "BAD GUY"
        case "caution": label = "CAUTION"
        default: label = nil  // not an organism
        }
        if let label {
            return "ID: \(c.id)\nVERDICT: \(label)\n\n\(c.note)"
        }
        return c.note  // no banner (e.g. not a plant or animal)
    }

    /// Downscale to keep the upload small and fast (long edge ≤ 1024).
    private static func jpeg(from ciImage: CIImage) -> Data? {
        let context = CIContext()
        let extent = ciImage.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let scale = min(1, 1024 / max(extent.width, extent.height))
        let scaled = scale < 1
            ? ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : ciImage
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.8)
    }
}
