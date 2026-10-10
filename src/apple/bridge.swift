// src/apple/bridge.swift — C entry points to macOS's on-device language model
// (the FoundationModels framework, macOS 26+), called from src/apple.rs.
// build.rs compiles this into a static library when the `apple` feature is on.
// The framework is weak-linked: on older macOS the status reads "unsupported"
// and the binary still runs.
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// 0 available · 1 device not eligible · 2 Apple Intelligence turned off ·
/// 3 model not ready (still downloading) · 4 other · 5 OS / SDK without the framework
@_cdecl("evolua_apple_status")
public func evolua_apple_status() -> Int32 {
#if canImport(FoundationModels)
    if #available(macOS 26.0, *) {
        switch SystemLanguageModel.default.availability {
        case .available:
            return 0
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return 1
            case .appleIntelligenceNotEnabled: return 2
            case .modelNotReady: return 3
            @unknown default: return 4
            }
        @unknown default:
            return 4
        }
    }
#endif
    return 5
}

private final class Reply: @unchecked Sendable {
    var text: String?
    var error: String?
}

/// One-shot answer from a fresh session (no conversation carried over). Blocks
/// the calling (non-Swift) thread until the model answers. Returns NULL on
/// failure and puts the reason in *err. Free both with evolua_apple_free.
@_cdecl("evolua_apple_complete")
public func evolua_apple_complete(
    _ system: UnsafePointer<CChar>, _ user: UnsafePointer<CChar>, _ maxTokens: Int32,
    _ err: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> UnsafeMutablePointer<CChar>? {
#if canImport(FoundationModels)
    if #available(macOS 26.0, *) {
        let instructions = String(cString: system)
        let prompt = String(cString: user)
        let reply = Reply()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let session = LanguageModelSession(instructions: instructions)
                let options = GenerationOptions(temperature: 0.2, maximumResponseTokens: Int(maxTokens))
                reply.text = try await session.respond(to: prompt, options: options).content
            } catch {
                reply.error = String(describing: error)
            }
            done.signal()
        }
        done.wait()
        if let text = reply.text { return strdup(text) }
        err?.pointee = strdup(reply.error ?? "unknown error")
        return nil
    }
#endif
    err?.pointee = strdup("the on-device model needs macOS 26 or later")
    return nil
}

@_cdecl("evolua_apple_free")
public func evolua_apple_free(_ p: UnsafeMutablePointer<CChar>?) {
    free(p)
}
