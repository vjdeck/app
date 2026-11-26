import Metal
import Foundation

final class SyphonOutputService {
    private let device: MTLDevice
    private var syphonServer: SyphonMetalServer?
    private let serverLock = NSLock()

    /// Tracks all in-use instance numbers across all SyphonOutputService instances.
    /// Prevents race condition when multiple windows restore simultaneously.
    private static let allocLock = NSLock()
    private static var allocatedNumbers: Set<Int> = []

    var isActive: Bool { syphonServer != nil }
    var hasClients: Bool { syphonServer?.hasClients ?? false }
    private(set) var instanceNumber: Int = 0

    init(device: MTLDevice) {
        self.device = device
    }

    /// Start with auto-assigned instance number (1-4).
    /// Instance number is fixed once assigned — only base name changes on restart.
    func startWithAutoName(baseName: String = "VJDeck") -> String {
        let cleanBase = Self.cleanBaseName(baseName)

        // Only auto-pick number on first start
        if instanceNumber == 0 {
            instanceNumber = Self.allocateNumber()
        }

        let name = "\(cleanBase) \(instanceNumber)"
        start(name: name)
        return name
    }

    /// Restart with new base name, keeping the same instance number.
    func restart(baseName: String) -> String {
        let cleanBase = Self.cleanBaseName(baseName)
        let name = "\(cleanBase) \(instanceNumber)"
        stop()
        start(name: name)
        return name
    }

    func start(name: String = "VJDeck") {
        stop()
        let server = SyphonMetalServer(name: name, device: device, options: nil)
        serverLock.lock()
        syphonServer = server
        serverLock.unlock()
        print("[Syphon] Server started: \(name)")
    }

    func stop() {
        serverLock.lock()
        let server = syphonServer
        syphonServer = nil
        serverLock.unlock()
        server?.stop()
    }

    /// Release the instance number back to the pool.
    func releaseNumber() {
        guard instanceNumber != 0 else { return }
        Self.allocLock.lock()
        Self.allocatedNumbers.remove(instanceNumber)
        Self.allocLock.unlock()
    }

    deinit {
        stop()
        releaseNumber()
    }

    func publishFrame(texture: MTLTexture, commandBuffer: MTLCommandBuffer, flipped: Bool = false) {
        serverLock.lock()
        let server = syphonServer
        serverLock.unlock()
        guard let server = server else { return }
        let region = NSRect(x: 0, y: 0, width: texture.width, height: texture.height)
        server.publishFrameTexture(texture, on: commandBuffer, imageRegion: region, flipped: flipped)
    }

    // MARK: - Private

    /// Strip trailing " N" from base name to prevent "Name 1 2"
    private static func cleanBaseName(_ name: String) -> String {
        name.replacingOccurrences(of: #"\s+\d+$"#, with: "", options: .regularExpression)
    }

    /// Atomically allocate the first available instance number (1-4).
    private static func allocateNumber() -> Int {
        allocLock.lock()
        defer { allocLock.unlock() }
        for n in 1...4 {
            if !allocatedNumbers.contains(n) {
                allocatedNumbers.insert(n)
                return n
            }
        }
        // All slots taken — fallback (shouldn't happen with 4-window limit)
        return 1
    }
}
