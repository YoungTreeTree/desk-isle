import XCTest
import ImageIO
@testable import DeskIsle

private actor PicturePlaybackTransport: PictureFrameTransport {
    struct Sample: Sendable {
        let id: Int
        let start: Double
        let end: Double
        let bytes: Int
        let accepted: Bool
    }
    let device: LayoutUSB?
    let delay: Duration
    let failingID: Int?
    let native: Bool
    var samples: [Sample] = []
    var uploads: [Int: PictureAnimation] = [:]
    var nativeRequests = 0

    init(device: LayoutUSB? = nil, delay: Duration = .milliseconds(10), failingID: Int? = nil, native: Bool = false) {
        self.device = device; self.delay = delay; self.failingID = failingID; self.native = native
    }

    func supportsPictureAnimation() async throws -> Bool {
        guard native else { return false }
        return if let device { try await device.supportsPictureAnimation() } else { true }
    }
    func showPictureAnimation(_ animation: PictureAnimation, for component: Component) async throws {
        nativeRequests += 1
        if component.id == failingID { throw LayoutUSBError.message("Native cache full") }
        if let device { try await device.showPictureAnimation(animation, for: component) }
        uploads[component.id] = animation
    }

    func showFrame(_ jpeg: Data, alphaMask: Data?, for component: Component, maxJPEG: Int) async throws -> Bool {
        let start = ProcessInfo.processInfo.systemUptime
        if component.id == failingID { throw LayoutUSBError.message("Test transfer failure") }
        let accepted: Bool
        if let device {
            accepted = try await device.showFrame(jpeg, alphaMask: alphaMask, for: component, maxJPEG: maxJPEG)
        } else {
            try await Task.sleep(for: delay)
            accepted = true
        }
        samples.append(Sample(id: component.id, start: start, end: ProcessInfo.processInfo.systemUptime,
                              bytes: jpeg.count + (alphaMask?.count ?? 0), accepted: accepted))
        return accepted
    }
}

@MainActor
final class PicturePlaybackTests: XCTestCase {
    private func animation(count: Int = 12, delay: Double = 0.08) throws -> PictureAsset {
        let data = NSMutableData()
        let output = CGImageDestinationCreateWithData(data, "com.compuserve.gif" as CFString, count, nil)!
        let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        for index in 0..<count {
            context.setFillColor(CGColor(gray: CGFloat(index) / CGFloat(count), alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
            CGImageDestinationAddImage(output, context.makeImage()!,
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(output))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("picture-test-\(UUID()).gif")
        try (data as Data).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try PictureAsset.prepare(PictureFile(from: url))
    }

    private func runtime(_ transport: PicturePlaybackTransport, assets: [PictureAsset]) -> PictureRuntime {
        let components = assets.indices.map {
            Component(id: Component.pictureIDs.lowerBound + $0, x: $0 * 160, y: 0, width: 160, height: 160)
        }
        let layout = ScreenLayout(panel: .deskIsle, direction: .portrait, components: components)
        let runtime = PictureRuntime(usb: transport)
        runtime.context = { WidgetContext(draft: layout, applied: layout, connected: true, applying: false, revision: 0) }
        runtime.appliedPictures = Dictionary(uniqueKeysWithValues: zip(components.map(\.id), assets))
        return runtime
    }

    func testTwelveFrameWalkKeepsEveryPoseAndOriginalTiming() throws {
        let asset = try animation()
        let now = ProcessInfo.processInfo.systemUptime
        let indices = (0..<12).map { asset.frameIndex(at: now + Double($0) * 0.08) }
        XCTAssertEqual(Set(indices).count, 12, "Preparing a 12.5 FPS GIF must not discard alternating poses")
        for index in 0..<12 {
            let time = now + Double(index) * 0.08
            let boundary = asset.nextFrameTime(after: time)
            XCTAssertGreaterThan(boundary, time)
            XCTAssertLessThanOrEqual(boundary - time, 0.080_01)
            XCTAssertNotEqual(asset.frameIndex(at: boundary + 0.000_1), asset.frameIndex(at: time))
        }
        XCTAssertEqual(asset.frameIndex(at: now), asset.frameIndex(at: now + 0.96))
    }

    func testAnimationPacketAndCapabilityValidation() throws {
        let packet = try animation().animation(side: 160)
        XCTAssertEqual(packet.frameCount, 12)
        XCTAssertEqual(packet.durationMS, 960)
        XCTAssertEqual(packet.data.count % 64, 0)
        XCTAssertEqual(String(decoding: packet.data.prefix(4), as: UTF8.self), "DIGA")
        func u32(_ offset: Int) -> UInt32 {
            packet.data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
        }
        for index in 0..<12 {
            XCTAssertEqual(u32(16 + 16 * index), UInt32(index * 80))
            let offset = Int(u32(20 + 16 * index)), length = Int(u32(24 + 16 * index))
            XCTAssertEqual(offset % 64, 0)
            let source = CGImageSourceCreateWithData(packet.data.subdata(in: offset..<offset + length) as CFData, nil)
            let image = try XCTUnwrap(source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
            XCTAssertEqual(image.width, 160); XCTAssertEqual(image.height, 160)
        }
        let line = "DESKISLE_PICTURES 1 42 4194304 32768 8388608 144"
        XCTAssertNotNil(PictureAnimationCapabilities(line: line, sequence: 42))
        XCTAssertNil(PictureAnimationCapabilities(line: line, sequence: 41))
        XCTAssertNil(PictureAnimationCapabilities(line: line.replacingOccurrences(of: "32768", with: "65536"), sequence: 42))
        XCTAssertNil(PictureResidency.parse("DESKISLE_PICTURE 1 42 32775 192 123 160 160 0", sequence: 42))
        if let path = ProcessInfo.processInfo.environment["DESKISLE_PICTURE_PACK_FIXTURE"] {
            try packet.data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    func testUSBAnimationCapabilityDoesNotResolveToLegacyDefault() async {
        let device = LayoutUSB()
        // Without a connection the concrete USB implementation must report that
        // discovery is pending, rather than selecting the protocol's legacy default.
        do {
            _ = try await device.supportsPictureAnimation()
            XCTFail("Concrete USB capability implementation was bypassed")
        } catch { }
        do {
            let transport: any PictureFrameTransport = device
            _ = try await transport.supportsPictureAnimation()
            XCTFail("USB protocol witness must use the same capability implementation")
        } catch { }
    }

    func testNativeGIFsUploadOnceAndStopHostFrameLoop() async throws {
        let transport = PicturePlaybackTransport(native: true)
        let asset = try animation()
        let runtime = runtime(transport, assets: [asset, asset])
        runtime.updatePicturePlayback()
        try await Task.sleep(for: .milliseconds(400))
        await runtime.pausePlayback()
        let uploads = await transport.uploads
        let requests = await transport.nativeRequests
        let frames = await transport.samples
        XCTAssertEqual(uploads.count, 2)
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(runtime.nativePictures.count, 2)
        XCTAssertTrue(frames.isEmpty, "No per-frame JPEG sends on capable firmware")
        runtime.updatePicturePlayback()
        try await Task.sleep(for: .milliseconds(100))
        let laterRequests = await transport.nativeRequests
        XCTAssertEqual(laterRequests, 2, "Refreshing the app must not restart a host animation loop")
    }

    func testNativeUploadFailureDoesNotSilentlyStreamFrames() async throws {
        let id = Component.pictureIDs.lowerBound
        let transport = PicturePlaybackTransport(failingID: id, native: true)
        let runtime = runtime(transport, assets: [try animation()])
        runtime.updatePicturePlayback()
        try await Task.sleep(for: .milliseconds(150))
        await runtime.pausePlayback()
        let frames = await transport.samples
        XCTAssertTrue(frames.isEmpty)
        XCTAssertTrue(runtime.nativePictures.isEmpty)
        XCTAssertNotNil(runtime.pictureDisplayNotices[id])
    }

    func testConnectedNativePicturePlayback() async throws {
        guard let path = ProcessInfo.processInfo.environment["DESKISLE_NATIVE_GIF_REPORT"] else {
            throw XCTSkip("Explicit opt-in hardware benchmark; app must be closed")
        }
        let device = LayoutUSB()
        let reply = try await device.readLayout()
        let layout = try XCTUnwrap(reply?.layout)
        XCTAssertTrue(layout.model3D == nil || reply?.modelResident == true, "Keep the applied 3D workload resident")
        let supports = try await device.supportsPictureAnimation()
        XCTAssertTrue(supports)
        guard supports else { return }
        let library = try LayoutLibraryStore.local.load().library
        let selection = try XCTUnwrap(library.displayed)
        XCTAssertEqual(layout, selection.scene.layout)
        guard layout == selection.scene.layout else { return }
        let prepared = try LayoutLibraryStore.local.prepare(selection.scene)
        let transport = PicturePlaybackTransport(device: device, native: true)
        let runtime = PictureRuntime(usb: transport)
        runtime.context = { WidgetContext(draft: layout, applied: layout, connected: true, applying: false, revision: 0) }
        runtime.appliedPictures = prepared.pictures
        await runtime.displayAllPictures(in: layout)
        await runtime.pausePlayback()
        XCTAssertTrue(runtime.pictureDisplayNotices.isEmpty)
        let ids = runtime.nativePictures.sorted()
        XCTAssertFalse(ids.isEmpty)
        var before: [Int: PictureAnimationStats] = [:]
        for id in ids { before[id] = try await device.pictureAnimationStatistics(id) }
        let initialFrames = await transport.samples.count
        // Close the transport completely, including CH343's multiplexed session.
        // No frames, keepalives, layout polls, or native control calls during this window.
        await device.disconnect()
        try await Task.sleep(for: .seconds(20))
        _ = try await device.readLayout()
        var report: [[String: Any]] = []
        for id in ids {
            let a = before[id]!, b = try await device.pictureAnimationStatistics(id)
            let elapsed = Double(b.elapsedUS - a.elapsedUS) / 1_000_000
            XCTAssertGreaterThan(b.presented, a.presented)
            XCTAssertEqual(b.state, 0)
            report.append(["id": id, "cached_bytes": b.bytes, "source_frames": b.frameCount,
                           "duration_ms": b.durationMS, "seconds": elapsed,
                           "presented_fps": Double(b.presented - a.presented) / elapsed,
                           "decoded_fps": Double(b.decoded - a.decoded) / elapsed,
                           "mean_decode_ms": Double(b.decodeUS - a.decodeUS) / Double(max(1, b.decoded - a.decoded)) / 1000,
                           "psram_delta": b.freePSRAM - a.freePSRAM])
        }
        // Simulate a lost board cache. The saved snapshot repairs it without host streaming.
        if let id = ids.first {
            try await device.pictureAnimationControl(id, action: 3)
            let missing = try await device.pictureAnimationStatistics(id)
            XCTAssertEqual(missing.bytes, 0)
            _ = try await device.readLayout()
            await runtime.displayStillPictures(in: layout)
            let restored = try await device.pictureAnimationStatistics(id)
            XCTAssertGreaterThan(restored.bytes, 0)
            XCTAssertEqual(restored.state, 0)
        }
        let frames = await transport.samples
        XCTAssertEqual(frames.count, initialFrames, "Native playback must not send any per-frame JPEGs")
        let data = try JSONSerialization.data(withJSONObject: ["host_frame_packets": frames.count - initialFrames,
                                                               "model_resident": reply?.modelResident ?? false, "components": report],
                                             options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        print(String(decoding: data, as: UTF8.self))
    }

    func testTwoGIFsDoNotShareOneFrameRateLimit() async throws {
        let asset = try animation()
        let transport = PicturePlaybackTransport(delay: .milliseconds(15))
        let runtime = runtime(transport, assets: [asset, asset])
        runtime.updatePicturePlayback()
        try await Task.sleep(for: .milliseconds(650))
        await runtime.pausePlayback()
        let samples = await transport.samples
        for id in runtime.appliedPictures.keys {
            XCTAssertGreaterThanOrEqual(samples.filter { $0.id == id }.count, 7,
                                        "Each GIF should follow its own 80 ms timeline, including transfer time")
        }
        for pair in zip(samples, samples.dropFirst()) {
            XCTAssertGreaterThanOrEqual(pair.1.start, pair.0.end, "Serial packets must not overlap")
        }
    }

    func testLongFrameDoesNotResendAndPauseWakesSleep() async throws {
        let transport = PicturePlaybackTransport()
        let runtime = runtime(transport, assets: [try animation(count: 2, delay: 10)])
        runtime.updatePicturePlayback()
        try await Task.sleep(for: .milliseconds(200))
        let start = ProcessInfo.processInfo.systemUptime
        await runtime.pausePlayback()
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.15)
        let samples = await transport.samples
        XCTAssertEqual(samples.count, 1)
    }

    func testFailedGIFDoesNotDelayOtherGIF() async throws {
        let asset = try animation()
        let transport = PicturePlaybackTransport(failingID: Component.pictureIDs.lowerBound)
        let runtime = runtime(transport, assets: [asset, asset])
        runtime.updatePicturePlayback()
        try await Task.sleep(for: .milliseconds(500))
        await runtime.pausePlayback()
        let samples = await transport.samples
        XCTAssertGreaterThanOrEqual(samples.count, 5)
        XCTAssertNotNil(runtime.pictureDisplayNotices[Component.pictureIDs.lowerBound])
    }

    func testSlowTransfersRemainFairAndDrainOnPause() async throws {
        let asset = try animation()
        let transport = PicturePlaybackTransport(delay: .milliseconds(110))
        let runtime = runtime(transport, assets: [asset, asset])
        runtime.updatePicturePlayback()
        try await Task.sleep(for: .milliseconds(520))
        await runtime.pausePlayback()
        let samples = await transport.samples
        let first = samples.filter { $0.id == Component.pictureIDs.lowerBound }.count
        let second = samples.count - first
        XCTAssertGreaterThanOrEqual(min(first, second), 2)
        XCTAssertLessThanOrEqual(abs(first - second), 1)
    }

    // Explicit opt-in: only streams pictures already present in the device's current
    // layout. Never changes layout, wallpaper, firmware, or the user's library.
    func testConnectedPictureThroughput() async throws {
        guard let reportPath = ProcessInfo.processInfo.environment["DESKISLE_PICTURE_BENCHMARK_REPORT"] else {
            throw XCTSkip("Hardware benchmark requires an explicit report path and the app to be closed")
        }
        let store = LayoutLibraryStore.local
        let library = try store.load().library
        let selection = try XCTUnwrap(library.displayed)
        let device = LayoutUSB()
        let reply = try await device.readLayout()
        XCTAssertEqual(reply?.layout, selection.scene.layout)
        guard reply?.layout == selection.scene.layout else { return }
        let prepared = try store.prepare(selection.scene)
        let layout = selection.scene.layout
        let animated = layout.components.filter { $0.isPicture && prepared.pictures[$0.id]?.isAnimated == true }
        guard !animated.isEmpty else { XCTFail("No GIFs in the applied layout"); return }
        var reports: [[String: Any]] = []
        // Both phases use identical prepared frames. The baseline isolates the old
        // post-transfer 125 ms sleep; it does not recreate the old import-time decimation.
        for mode in ["legacy_schedule", "independent_timelines"] {
            let transport = PicturePlaybackTransport(device: device)
            let runtime = PictureRuntime(usb: transport)
            runtime.context = { WidgetContext(draft: layout, applied: layout, connected: true, applying: false, revision: 0) }
            runtime.appliedPictures = prepared.pictures
            let start = ProcessInfo.processInfo.systemUptime
            if mode == "legacy_schedule" {
                var next = 0
                while ProcessInfo.processInfo.systemUptime - start < 20 {
                    let component = animated[next % animated.count]
                    next += 1
                    await runtime.displayPicture(prepared.pictures[component.id]!, for: component, maxJPEG: layout.panel.maxJPEG)
                    try await Task.sleep(for: .milliseconds(125))
                }
            } else {
                runtime.updatePicturePlayback()
                try await Task.sleep(for: .seconds(20))
                await runtime.pausePlayback()
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            let samples = await transport.samples
            var components: [[String: Any]] = []
            for component in animated {
                let frames = samples.filter { $0.id == component.id && $0.accepted }
                guard !frames.isEmpty else { XCTFail("No accepted frames for \(component.id)"); continue }
                let times = frames.map { ($0.end - $0.start) * 1_000 }.sorted()
                components.append(["id": component.id, "accepted_frames": frames.count,
                                   "accepted_fps": Double(frames.count) / elapsed,
                                   "mean_transfer_ms": times.reduce(0, +) / Double(times.count),
                                   "p95_transfer_ms": times[min(times.count - 1, Int(Double(times.count) * 0.95))],
                                   "mean_payload_bytes": frames.map(\.bytes).reduce(0, +) / frames.count])
            }
            XCTAssertTrue(runtime.pictureDisplayNotices.isEmpty)
            reports.append(["mode": mode, "seconds": elapsed, "components": components,
                            "errors": runtime.pictureDisplayNotices.map { "\($0.key): \($0.value)" }])
        }
        let data = try JSONSerialization.data(withJSONObject: reports,
                                             options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: reportPath), options: .atomic)
        print(String(decoding: data, as: UTF8.self))
    }
}
