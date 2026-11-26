import Darwin
import Foundation
import FFmpeg

/// Reads container metadata only. Never opens a decoder, scans packets, or
/// calls avformat_find_stream_info (which may decode and scan to EOF).
enum MediaDurationProbe {
    static let maximumBytesRead = 2 * 1024 * 1024

    struct Result {
        let duration: Double?
        let bytesRead: Int
    }

    static func duration(of url: URL) -> Double? {
        inspect(url).duration
    }

    static func inspect(_ url: URL, byteLimit: Int = maximumBytesRead) -> Result {
        guard url.isFileURL, !Task.isCancelled,
              let input = Input(url: url, byteLimit: byteLimit) else {
            return Result(duration: nil, bytesRead: 0)
        }
        let opaque = Unmanaged.passUnretained(input).toOpaque()
        guard let buffer = av_malloc(32 * 1024)?.assumingMemoryBound(to: UInt8.self) else {
            return Result(duration: nil, bytesRead: 0)
        }
        let io = avio_alloc_context(buffer, 32 * 1024, 0, opaque, { opaque, buffer, size in
            guard let opaque, let buffer else { return -Int32(EIO) }
            return Unmanaged<Input>.fromOpaque(opaque).takeUnretainedValue().read(buffer, size: size)
        }, nil, { opaque, offset, whence in
            guard let opaque else { return -Int64(EIO) }
            return Unmanaged<Input>.fromOpaque(opaque).takeUnretainedValue().seek(offset, whence: whence)
        })
        guard let io else {
            av_free(buffer)
            return Result(duration: nil, bytesRead: 0)
        }
        // libav may replace the original buffer, so free the current one.
        defer {
            av_free(io.pointee.buffer)
            var context: UnsafeMutablePointer<AVIOContext>? = io
            avio_context_free(&context)
            withExtendedLifetime(input) {}
        }
        var format = avformat_alloc_context()
        guard let allocatedFormat = format else {
            return Result(duration: nil, bytesRead: 0)
        }
        defer { avformat_close_input(&format) }
        allocatedFormat.pointee.pb = io
        allocatedFormat.pointee.flags |= AVFMT_FLAG_CUSTOM_IO
        // Container references must not open extra files or network streams
        // outside the bounded input above (for example HLS segments).
        allocatedFormat.pointee.io_open = { _, _, _, _, _ in -Int32(EPERM) }
        allocatedFormat.pointee.probesize = Int64(max(32, byteLimit))
        allocatedFormat.pointee.interrupt_callback = AVIOInterruptCB(callback: { opaque in
            guard let opaque else { return 1 }
            return Unmanaged<Input>.fromOpaque(opaque).takeUnretainedValue().shouldStop ? 1 : 0
        }, opaque: opaque)

        let status = avformat_open_input(&format, url.path, nil, nil)
        guard status >= 0, let format, !input.shouldStop else {
            return Result(duration: nil, bytesRead: input.bytesRead)
        }
        var durations: [Double] = []
        var earliestStart = Double.infinity
        var latestEnd = -Double.infinity
        if format.pointee.duration > 0 {
            durations.append(Double(format.pointee.duration) / Double(AV_TIME_BASE))
        }
        for index in 0..<Int(format.pointee.nb_streams) {
            guard let stream = format.pointee.streams[index],
                  let parameters = stream.pointee.codecpar,
                  parameters.pointee.codec_type == AVMEDIA_TYPE_VIDEO
                    || parameters.pointee.codec_type == AVMEDIA_TYPE_AUDIO,
                  stream.pointee.duration > 0 else { continue }
            let timeBase = av_q2d(stream.pointee.time_base)
            let duration = Double(stream.pointee.duration) * timeBase
            guard duration.isFinite, duration > 0 else { continue }
            durations.append(duration)
            if stream.pointee.start_time != Int64.min { // AV_NOPTS_VALUE
                let start = Double(stream.pointee.start_time) * timeBase
                earliestStart = min(earliestStart, start)
                latestEnd = max(latestEnd, start + duration)
            }
        }
        // Streams may start at different times. Their combined timeline can
        // exceed 30 minutes even when every individual stream is shorter.
        durations.append(latestEnd - earliestStart)
        return Result(
            duration: durations.filter { $0.isFinite && $0 > 0 }.max(),
            bytesRead: input.bytesRead
        )
    }

    private final class Input {
        let descriptor: Int32
        let fileSize: Int64
        let byteLimit: Int
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        private(set) var bytesRead = 0
        private var exhausted = false

        init?(url: URL, byteLimit: Int) {
            let fd = Darwin.open(url.path, O_RDONLY | O_NONBLOCK)
            guard fd >= 0 else { return nil }
            var info = stat()
            guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
                Darwin.close(fd)
                return nil
            }
            descriptor = fd
            fileSize = info.st_size
            self.byteLimit = max(0, byteLimit)
        }

        deinit { Darwin.close(descriptor) }

        var shouldStop: Bool {
            exhausted || Task.isCancelled || ProcessInfo.processInfo.systemUptime >= deadline
        }

        func read(_ buffer: UnsafeMutablePointer<UInt8>, size: Int32) -> Int32 {
            guard !shouldStop else { return -Int32(EIO) }
            let count = min(Int(size), byteLimit - bytesRead)
            guard count > 0 else {
                exhausted = true
                return -Int32(EIO)
            }
            let readCount = Darwin.read(descriptor, buffer, count)
            guard readCount >= 0 else { return -errno }
            bytesRead += readCount
            // AVERROR_EOF is a C function-like macro unavailable in Swift.
            return readCount == 0 ? -541478725 : Int32(readCount)
        }

        func seek(_ offset: Int64, whence: Int32) -> Int64 {
            guard !shouldStop else { return -Int64(EIO) }
            if whence & AVSEEK_SIZE != 0 { return fileSize }
            let result = lseek(descriptor, offset, whence & ~AVSEEK_FORCE)
            return result < 0 ? -Int64(errno) : result
        }
    }
}
