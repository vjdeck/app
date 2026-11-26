import SwiftUI
import CoreAudio

struct AppSettingsSnapshot: Sendable {
    let normalizeAudio: Bool
    let masterTempo: Bool
    let selectedOutputDeviceID: AudioDeviceID?
    let frameCacheMB: Int
    let timelinePreviewCacheMB: Int
}

func defaultTimelinePreviewCacheMB(forFrameCacheMB frameCacheMB: Int) -> Int {
    return max(500, min(4000, frameCacheMB * 4))
}

enum DeckPlaybackRate {
    static let minimum: Float = 0.90
    static let maximum: Float = 1.10
    static let defaultRate: Float = 1.00

    static func clamped(_ rate: Float) -> Float {
        min(maximum, max(minimum, rate))
    }

    static func rate(forNormalizedPosition position: Float) -> Float {
        let position = min(1, max(0, position))
        return minimum + position * (maximum - minimum)
    }

    static func normalizedPosition(for rate: Float) -> Float {
        (clamped(rate) - minimum) / (maximum - minimum)
    }

    /// Auto Sync owns the actual rate while active. The operator's fader value
    /// remains stored and becomes effective again when sync releases control.
    static func resolvedRate(base: Float, autoSyncRate: Float?) -> Float {
        guard let autoSyncRate,
              autoSyncRate.isFinite,
              autoSyncRate > 0 else {
            return clamped(base)
        }
        return autoSyncRate
    }
}

/// Global settings shared across all windows
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var syphonBaseName: String = {
        UserDefaults.standard.string(forKey: "syphonBaseName") ?? "VJDeck"
    }() {
        didSet { UserDefaults.standard.set(syphonBaseName, forKey: "syphonBaseName") }
    }
    @Published var latencyOffset: Double = {
        let ud = UserDefaults.standard
        return ud.object(forKey: "latencyOffset") != nil ? ud.double(forKey: "latencyOffset") : -0.12
    }() {
        didSet { UserDefaults.standard.set(latencyOffset, forKey: "latencyOffset") }
    }
    @Published var selectedInputDeviceID: AudioDeviceID? = {
        let v = UserDefaults.standard.integer(forKey: "selectedInputDeviceID")
        return v > 0 ? AudioDeviceID(v) : nil
    }() {
        didSet {
            if let id = selectedInputDeviceID {
                UserDefaults.standard.set(Int(id), forKey: "selectedInputDeviceID")
            } else {
                UserDefaults.standard.removeObject(forKey: "selectedInputDeviceID")
            }
        }
    }

    @Published var selectedOutputDeviceID: AudioDeviceID? = {
        let v = UserDefaults.standard.integer(forKey: "selectedOutputDeviceID")
        return v > 0 ? AudioDeviceID(v) : nil
    }() {
        didSet {
            if let id = selectedOutputDeviceID {
                UserDefaults.standard.set(Int(id), forKey: "selectedOutputDeviceID")
            } else {
                UserDefaults.standard.removeObject(forKey: "selectedOutputDeviceID")
            }
            NotificationCenter.default.post(name: .audioOutputDeviceChanged, object: nil)
        }
    }

    @Published var normalizeAudio: Bool = {
        let ud = UserDefaults.standard
        return ud.object(forKey: "normalizeAudio") != nil ? ud.bool(forKey: "normalizeAudio") : true
    }() {
        didSet { UserDefaults.standard.set(normalizeAudio, forKey: "normalizeAudio") }
    }

    @Published var masterTempo: Bool = {
        let ud = UserDefaults.standard
        return ud.object(forKey: "masterTempo") != nil ? ud.bool(forKey: "masterTempo") : true
    }() {
        didSet { UserDefaults.standard.set(masterTempo, forKey: "masterTempo") }
    }

    @Published var hideToolbarButtons: Bool = {
        let ud = UserDefaults.standard
        return ud.object(forKey: "hideToolbarButtons") != nil ? ud.bool(forKey: "hideToolbarButtons") : false
    }() {
        didSet { UserDefaults.standard.set(hideToolbarButtons, forKey: "hideToolbarButtons") }
    }

    @Published var slowRate: Float = {
        let ud = UserDefaults.standard
        return ud.object(forKey: "slowRate") != nil ? ud.float(forKey: "slowRate") : 0.8
    }() {
        didSet { UserDefaults.standard.set(slowRate, forKey: "slowRate") }
    }
    @Published var fastRate: Float = {
        let ud = UserDefaults.standard
        return ud.object(forKey: "fastRate") != nil ? ud.float(forKey: "fastRate") : 1.2
    }() {
        didSet { UserDefaults.standard.set(fastRate, forKey: "fastRate") }
    }
    @Published var markerMagnetic: Bool = {
        let ud = UserDefaults.standard
        return ud.object(forKey: "markerMagnetic") != nil ? ud.bool(forKey: "markerMagnetic") : true
    }() {
        didSet { UserDefaults.standard.set(markerMagnetic, forKey: "markerMagnetic") }
    }

    /// Memory budget for frame cache in MB (forward queue + backward cache combined)
    @Published var frameCacheMB: Int = {
        let ud = UserDefaults.standard
        return ud.object(forKey: "frameCacheMB") != nil ? ud.integer(forKey: "frameCacheMB") : 500
    }() {
        didSet { UserDefaults.standard.set(frameCacheMB, forKey: "frameCacheMB") }
    }

    /// Memory budget for full-track mini-waveform preview frames in MB.
    @Published var timelinePreviewCacheMB: Int = {
        let ud = UserDefaults.standard
        if ud.object(forKey: "timelinePreviewCacheMB") != nil {
            return ud.integer(forKey: "timelinePreviewCacheMB")
        }
        let frameBudget = ud.object(forKey: "frameCacheMB") != nil ? ud.integer(forKey: "frameCacheMB") : 500
        return defaultTimelinePreviewCacheMB(forFrameCacheMB: frameBudget)
    }() {
        didSet { UserDefaults.standard.set(timelinePreviewCacheMB, forKey: "timelinePreviewCacheMB") }
    }

    /// On-disk budget for downloaded web videos. Zero means unlimited.
    @Published var webVideoCacheLimitGB: Int = {
        let defaults = UserDefaults.standard
        let stored = defaults.object(forKey: WebVideoCachePolicy.userDefaultsKey) == nil
            ? WebVideoCachePolicy.defaultLimitGB
            : defaults.integer(forKey: WebVideoCachePolicy.userDefaultsKey)
        return WebVideoCachePolicy.normalizedLimitGB(stored)
    }() {
        didSet {
            UserDefaults.standard.set(
                WebVideoCachePolicy.normalizedLimitGB(webVideoCacheLimitGB),
                forKey: WebVideoCachePolicy.userDefaultsKey
            )
        }
    }

    // MARK: - Master Output

    /// Master output height: 1080, 720, or 480
    @Published var masterResolution: Int = {
        let ud = UserDefaults.standard
        let v = ud.integer(forKey: "masterResolution")
        return v > 0 ? v : 1080
    }() {
        didSet { UserDefaults.standard.set(masterResolution, forKey: "masterResolution") }
    }

    /// Master output frame rate: 24, 30, or 60
    @Published var masterFrameRate: Int = {
        let ud = UserDefaults.standard
        let v = ud.integer(forKey: "masterFrameRate")
        return v > 0 ? v : 60
    }() {
        didSet { UserDefaults.standard.set(masterFrameRate, forKey: "masterFrameRate") }
    }

    /// Master output width derived from 16:9 aspect ratio
    var masterWidth: Int { masterResolution * 16 / 9 }

    // MARK: - OSC

    /// Off by default so the app does not open a network port until asked.
    @Published var oscEnabled: Bool = {
        UserDefaults.standard.bool(forKey: "oscEnabled")
    }() {
        didSet { UserDefaults.standard.set(oscEnabled, forKey: "oscEnabled") }
    }

    /// UDP port that receives OSC from control surfaces.
    @Published var oscPort: Int = {
        let ud = UserDefaults.standard
        return ud.object(forKey: "oscPort") != nil ? ud.integer(forKey: "oscPort") : OSCService.defaultPort
    }() {
        didSet { UserDefaults.standard.set(oscPort, forKey: "oscPort") }
    }

    /// Comma-separated IP addresses allowed to send OSC. Empty accepts any sender.
    @Published var oscAllowedSenders: String = {
        UserDefaults.standard.string(forKey: "oscAllowedSenders") ?? ""
    }() {
        didSet { UserDefaults.standard.set(oscAllowedSenders, forKey: "oscAllowedSenders") }
    }

    var snapshot: AppSettingsSnapshot {
        AppSettingsSnapshot(
            normalizeAudio: normalizeAudio,
            masterTempo: masterTempo,
            selectedOutputDeviceID: selectedOutputDeviceID,
            frameCacheMB: frameCacheMB,
            timelinePreviewCacheMB: timelinePreviewCacheMB
        )
    }

    private init() {}
}
