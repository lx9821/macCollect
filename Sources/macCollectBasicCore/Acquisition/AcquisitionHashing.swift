import CryptoKit
import Darwin
import Foundation

final class AcquisitionHasher {
    private let cancellationToken: CancellationToken?
    private let log: AcquisitionRunner.LogHandler

    init(cancellationToken: CancellationToken?, log: @escaping AcquisitionRunner.LogHandler) {
        self.cancellationToken = cancellationToken
        self.log = log
    }

    func hashFile(_ url: URL, methods: [AcquisitionHashMethod]) throws -> String {
        log("Hashing output image")
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw AcquisitionError.command("Could not open image for hashing: \(String(cString: strerror(errno)))")
        }
        defer { close(descriptor) }
        _ = fcntl(descriptor, F_NOCACHE, 1)

        var md5 = Insecure.MD5()
        var sha256 = SHA256()
        let chunkSize = 4 * 1024 * 1024
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            if cancellationToken?.isCancelled == true { throw AcquisitionError.cancelled }
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, chunkSize)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw AcquisitionError.command("Hashing read failed: \(String(cString: strerror(errno)))")
            }
            let data = Data(bytes: buffer, count: count)
            if methods.contains(.md5) { md5.update(data: data) }
            if methods.contains(.sha256) { sha256.update(data: data) }
        }

        return methods.map { method in
            let digest = (method == .md5 ? Array(md5.finalize()) : Array(sha256.finalize()))
                .map { String(format: "%02x", $0) }
                .joined()
            log("[hash] \(method.label): \(digest)")
            return "\(method.label): \(digest)"
        }.joined(separator: "\n")
    }
}
