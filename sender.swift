// sender.swift — 2025 MacBook'ta derle ve çalıştır
// swiftc sender.swift -o sender -framework ScreenCaptureKit && ./sender <2018-mac-ip>
import Foundation
import CoreGraphics
import AppKit
import Network
import ImageIO
import ScreenCaptureKit

// MARK: - Ekran listesi

func getActiveDisplayIDs() -> [CGDirectDisplayID] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 8)
    var count: UInt32 = 0
    CGGetActiveDisplayList(8, &ids, &count)
    return Array(ids.prefix(Int(count)))
}

func listDisplays() {
    let ids = getActiveDisplayIDs()
    print("Mevcut ekranlar:")
    for (i, id) in ids.enumerated() {
        let w    = CGDisplayPixelsWide(id)
        let h    = CGDisplayPixelsHigh(id)
        let main = id == CGMainDisplayID() ? " [Ana ekran]" : ""
        print("  [\(i)] ID=\(id)  \(w)×\(h)\(main)")
    }
}

// MARK: - ScreenCaptureKit ile yakalama

actor Capturer {
    private var stream: SCStream?
    private var output: FrameOutput?

    func setup(displayID: CGDirectDisplayID) async throws {
        let content  = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == displayID })
                         ?? content.displays.first
        else { throw NSError(domain: "DisplayStream", code: 1, userInfo: [NSLocalizedDescriptionKey: "Ekran bulunamadı"]) }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cfg    = SCStreamConfiguration()
        cfg.width  = min(display.width,  1920)
        cfg.height = min(display.height, 1080)
        cfg.pixelFormat           = kCVPixelFormatType_32BGRA
        cfg.minimumFrameInterval  = CMTime(value: 1, timescale: 15) // 15 FPS
        cfg.showsCursor           = true

        let out    = FrameOutput()
        output     = out
        stream     = SCStream(filter: filter, configuration: cfg, delegate: nil)
        try stream!.addStreamOutput(out, type: .screen, sampleHandlerQueue: DispatchQueue.global(qos: .userInteractive))
        try await stream!.startCapture()
    }

    func nextFrame() async -> Data? {
        output?.dequeueJPEG()
    }
}

final class FrameOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private var latest: CVPixelBuffer?
    private let lock = NSLock()

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pb = sb.imageBuffer else { return }
        lock.withLock { latest = pb }
    }

    func dequeueJPEG() -> Data? {
        let pb = lock.withLock { () -> CVPixelBuffer? in
            defer { latest = nil }
            return latest
        }
        guard let pb else { return nil }
        return pixelBufferToJPEG(pb)
    }
}

func pixelBufferToJPEG(_ pb: CVPixelBuffer, quality: Double = 0.65) -> Data? {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }

    let w   = CVPixelBufferGetWidth(pb)
    let h   = CVPixelBufferGetHeight(pb)
    let bpr = CVPixelBufferGetBytesPerRow(pb)
    guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }

    guard let cs  = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: base, width: w, height: h,
                              bitsPerComponent: 8, bytesPerRow: bpr,
                              space: cs,
                              bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
          let img  = ctx.makeImage()
    else { return nil }

    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return out as Data
}

// MARK: - Length-prefix gönderme

func sendFrame(_ data: Data, conn: NWConnection) {
    var n   = UInt32(data.count).bigEndian
    let pkt = Data(bytes: &n, count: 4) + data
    conn.send(content: pkt, completion: .contentProcessed { _ in })
}

// MARK: - Argümanlar

let args = CommandLine.arguments
guard args.count > 1 else {
    print("""
    Kullanım:
      ./sender <ip>            → ana ekranı gönderir (mirror)
      ./sender <ip> list       → bağlı ekranları listeler
      ./sender <ip> <index>    → belirli ekranı gönderir (extended için 1 gir)

    NOT: İlk çalıştırmada macOS Ekran Kaydı izni isteyecek — izin ver.
    """)
    exit(1)
}

let receiverHost = args[1]

if args.count > 2 && args[2] == "list" {
    listDisplays()
    exit(0)
}

let screenIndex = args.count > 2 ? (Int(args[2]) ?? 0) : 0
let displayIDs  = getActiveDisplayIDs()
guard screenIndex < displayIDs.count else {
    print("Geçersiz ekran indexi. 'list' ile kontrol et.")
    exit(1)
}
let targetID = displayIDs[screenIndex]
let w = CGDisplayPixelsWide(targetID)
let h = CGDisplayPixelsHigh(targetID)
print("Ekran \(screenIndex) → ID=\(targetID) (\(w)×\(h)) gönderiliyor")

// MARK: - TCP Bağlantısı

let conn = NWConnection(host: .init(receiverHost), port: 7878, using: .tcp)
var ready = false

conn.stateUpdateHandler = { state in
    switch state {
    case .ready:
        print("Bağlandı → \(receiverHost):7878")
        ready = true
    case .failed(let e):
        print("Bağlantı hatası: \(e)")
        exit(1)
    default: break
    }
}
conn.start(queue: .global())

let deadline = Date().addingTimeInterval(10)
while !ready && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
guard ready else { print("Bağlantı zaman aşımına uğradı"); exit(1) }

// MARK: - Yakalama + Yayın

let capturer = Capturer()

Task {
    do {
        try await capturer.setup(displayID: targetID)
        print("Yayın başladı — durdurmak için Ctrl+C")

        let interval = 1.0 / 15.0
        while true {
            let t0 = Date()
            if let data = await capturer.nextFrame() {
                sendFrame(data, conn: conn)
            }
            let wait = interval + t0.timeIntervalSinceNow
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        }
    } catch {
        print("Hata: \(error)")
        exit(1)
    }
}

RunLoop.main.run()
