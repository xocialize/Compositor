import AppKit
import Foundation
import ImageIO
import Testing
@testable import Compositor

/// Forge Canvas P0 step 3b — writes parity fixtures through Compositor's own editor actions, with the
/// app's own flattened export as the oracle for each. Runs only when `COMP_FIXTURE_OUT` is set
/// (pass `TEST_RUNNER_COMP_FIXTURE_OUT=<dir>` to xcodebuild), so ordinary test runs never write files.
///
/// Every fixture is re-opened with `ProjectStore.load` before it is kept: a fixture the app cannot
/// read back is a bug report, not a fixture.
@MainActor
@Suite(.serialized)
struct CanvasFixtureGenerator {
    static let outputPath = ProcessInfo.processInfo.environment["COMP_FIXTURE_OUT"]
    static let side = 64

    struct Entry: Encodable {
        let name, group, oracle: String
        let formatVersion: Int
        let features: [String]
        var blendMode: String? = nil
        var oracleEngine: String? = nil
        /// True when the oracle is byte-identical to the same document without the feature under test —
        /// i.e. the fixture does not actually exercise it. Recorded, not hidden.
        var identicalToControl: Bool? = nil
        /// True where the layer picks a random seed at creation (`addAdjustment`) and saves it. The oracle is a
        /// function of the saved file — `committedOraclesReproduceFromTheirDocuments` — but regenerating the set makes
        /// new layers with new seeds. (Rev 1 of this field claimed the render itself was random; it is not.)
        var seededAtCreation: Bool? = nil
    }

    /// Adjustment kinds whose defaults are an identity (or within 1 LSB of one) get settings that move pixels,
    /// set through the same `updateAdjustment` the editor uses. Measured on the first generation.
    private func tune(_ a: inout LayerAdjustment) -> Bool {
        switch a.kind {
        case .levels: a.levels.ranges[LevelsChannel.rgb.index] = LevelRange(black: 30, gamma: 1.4, white: 220)
        case .curves: a.curves.channels[LevelsChannel.rgb.index] =
            [CurvePoint(x: 0, y: 0), CurvePoint(x: 96, y: 60), CurvePoint(x: 160, y: 200), CurvePoint(x: 255, y: 255)]
        case .exposure: var e = ExposureSettings(); e.exposure = 0.8; a.exposureSettings = e
        case .colorBalance: var c = ColorBalanceSettings(); c.midCyanRed = 40; c.midYellowBlue = -35; a.colorBalanceSettings = c
        case .hsv: a.hue = 45; a.saturation = 30
        default: return false
        }
        return true
    }
    /// These pick a random seed when the layer is created, and save it.
    static let randomKinds: Set<AdjustmentKind> = [.grain, .addNoise]

    // MARK: images

    private func image(_ f: (Double, Double) -> (Double, Double, Double, Double)) throws -> ImportedImage {
        let n = Self.side
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = try #require(CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let px = try #require(ctx.data).assumingMemoryBound(to: UInt8.self)
        for y in 0..<n { for x in 0..<n {
            let (r, g, b, a) = f(Double(x) / Double(n - 1), Double(y) / Double(n - 1))
            let i = (y * n + x) * 4
            px[i] = UInt8((r * a * 255).rounded()); px[i+1] = UInt8((g * a * 255).rounded())
            px[i+2] = UInt8((b * a * 255).rounded()); px[i+3] = UInt8((a * 255).rounded())
        } }
        let img = try #require(ctx.makeImage())
        return ImportedImage(image: img, thumbnail: img, name: "Fixture")
    }
    /// Base: red across, green down, blue fixed — every channel value gets a partner on the top layer.
    private func base() throws -> ImportedImage { try image { x, y in (x, y, 0.5, 1) } }
    /// Top: the ramps crossed the other way, with a half-transparent right quarter so blending meets alpha.
    private func top() throws -> ImportedImage { try image { x, y in (1 - y, 0.35, x, x > 0.75 ? 0.5 : 1) } }
    /// A disc on transparency, so effects have an edge to work on.
    private func disc() throws -> ImportedImage {
        try image { x, y in hypot(x - 0.5, y - 0.5) < 0.3 ? (0.9, 0.4, 0.1, 1) : (0, 0, 0, 0) }
    }
    private var ellipse: DocumentSelection {
        let n = CGFloat(Self.side)
        return DocumentSelection(path: CGPath(ellipseIn: CGRect(x: n * 0.15, y: n * 0.2, width: n * 0.7, height: n * 0.55),
                                              transform: nil), antialiased: true, feather: 6)
    }

    // MARK: writing

    private func write(_ session: EditorSession, _ name: String, _ group: String, _ features: [String],
                       into root: URL, _ entries: inout [Entry], control: Data? = nil,
                       adjust: (inout Entry) -> Void = { _ in }) async throws -> Data {
        let snapshot = try #require(session.projectSnapshot(), "no document for \(name)")
        let dir = root.appendingPathComponent(group)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).comp")
        try? FileManager.default.removeItem(at: url)
        try await ProjectStore.shared.save(snapshot, to: url)
        let reopened = try await ProjectStore.shared.load(from: url)          // the app must read its own fixture
        #expect(reopened.manifest.layers.count == snapshot.manifest.layers.count, "\(name) lost layers on reopen")
        let png = try await ImageExporter.shared.pngData(snapshot)
        try png.write(to: dir.appendingPathComponent("\(name).oracle.png"))
        var entry = Entry(name: name, group: group, oracle: "\(group)/\(name).oracle.png",
                          formatVersion: snapshot.manifest.version, features: features)
        if let control { entry.identicalToControl = (png == control) }
        adjust(&entry)
        entries.append(entry)
        return png
    }

    private func twoLayer(_ mode: LayerBlendMode = .normal, opacity: Double = 1) throws -> EditorSession {
        let s = EditorSession()
        s.createDocument(width: Self.side, height: Self.side)
        s.insert(try base())
        s.insert(try top())
        s.setLayerBlendMode(mode)
        if opacity != 1 { s.setLayerOpacity(opacity) }
        return s
    }

    // MARK: the set

    @Test(.enabled(if: outputPath != nil)) func writeTheP0FixtureSet() async throws {
        let root = URL(fileURLWithPath: try #require(Self.outputPath))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var entries: [Entry] = []

        // Blend modes — all of them, not the nine the old format doc listed.
        let normal = try await write(try twoLayer(), "normal-control", "blend", ["blend:normal"], into: root, &entries)
        for mode in LayerBlendMode.allCases where mode != .normal {
            _ = try await write(try twoLayer(mode), String(describing: mode), "blend", ["blend:\(String(describing: mode))"], into: root, &entries,
                                control: normal) { e in
                e.blendMode = mode.rawValue
                e.oracleEngine = mode.coreImageFilter != nil ? "CoreImage, sRGB working space" : "CoreGraphics"
            }
        }

        // Opacity.
        _ = try await write(try twoLayer(opacity: 0.5), "half", "opacity", ["opacity:0.5"], into: root, &entries, control: normal)

        // Masks: a hide-all mask, and a feathered ellipse made the way a user makes one — marquee, then mask.
        let hide = try twoLayer(); hide.addLayerMask(revealing: false)
        _ = try await write(hide, "hide-all", "mask", ["mask:solid-hide"], into: root, &entries, control: normal)
        let shaped = try twoLayer(); shaped.setSelection(ellipse, name: "Ellipse"); shaped.addMask()
        _ = try await write(shaped, "ellipse-feathered", "mask", ["mask:selection", "feather:6"], into: root, &entries, control: normal)

        // Clipping chain: two layers clipped to one base (v5 live alpha links).
        let clip = EditorSession(); clip.createDocument(width: Self.side, height: Self.side)
        clip.insert(try disc())
        clip.insert(try base()); clip.setLayerBlendMode(.multiply)
        let first = try #require(clip.activeLayerID); clip.toggleClippingMask(first)
        clip.insert(try top()); clip.setLayerBlendMode(.screen)
        let second = try #require(clip.activeLayerID); clip.toggleClippingMask(second)
        _ = try await write(clip, "chain", "clip", ["clip:chain-of-2", "blend:multiply", "blend:screen"], into: root, &entries)

        // Folders: an outer folder at 60% with a feathered folder mask, holding a layer and a nested folder.
        let fold = EditorSession(); fold.createDocument(width: Self.side, height: Self.side)
        fold.insert(try base())
        fold.addGroup(); fold.setLayerOpacity(0.6)
        fold.setSelection(ellipse, name: "Ellipse"); fold.addMask(); fold.setSelection(nil, name: "Deselect")
        fold.insert(try top())                                   // inside the outer folder
        fold.addGroup()                                          // nested folder
        fold.insert(try disc()); fold.setLayerBlendMode(.overlay) // inside the nested folder
        _ = try await write(fold, "nested", "folder", ["folder:nested", "folder:opacity-0.6", "folder:mask"], into: root, &entries)

        // Effects on an edge: stroke, drop shadow, outer glow.
        let fx = EditorSession(); fx.createDocument(width: Self.side, height: Self.side)
        fx.insert(try base()); fx.insert(try disc())
        var effects = LayerEffects()
        effects.stroke = StrokeEffect(size: 3, red: 0.1, green: 0.1, blue: 0.8)
        effects.shadow = ShadowEffect(angle: 135, distance: 5, blur: 4)
        effects.outerGlow = OuterGlowEffect(size: 12, opacity: 1)   // size 6 at 0.75 moved pixels by ≤8 over ~3px
        fx.setEffects(effects)
        _ = try await write(fx, "stroke-shadow-glow", "effects", ["effect:stroke", "effect:shadow", "effect:outer-glow"], into: root, &entries)

        // Adjustment layers — every kind, at defaults. Kinds whose default is an identity are flagged, not hidden.
        let plain = EditorSession(); plain.createDocument(width: Self.side, height: Self.side); plain.insert(try base())
        let baseOnly = try await write(plain, "base-control", "adjust", ["control"], into: root, &entries)
        for kind in AdjustmentKind.allCases {
            let s = EditorSession(); s.createDocument(width: Self.side, height: Self.side)
            s.insert(try base()); s.addAdjustment(kind)
            var features = ["adjustment:\(String(describing: kind))", "settings:defaults"]
            if let id = s.activeLayerID, var value = s.activeLayer?.adjustment, tune(&value) {
                s.updateAdjustment(id, value: value); features[1] = "settings:tuned"
            }
            _ = try await write(s, String(describing: kind), "adjust", features, into: root, &entries, control: baseOnly) { e in
                if Self.randomKinds.contains(kind) { e.seededAtCreation = true }
            }
        }

        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entries).write(to: root.appendingPathComponent("index.json"))
        print("FIXTURES_WRITTEN \(entries.count) \(root.path)")
    }
    // MARK: verification — are the committed oracles reproducible from their saved documents?

    static let verifyPath = ProcessInfo.processInfo.environment["COMP_FIXTURE_VERIFY"]

    /// Loads every committed fixture with the app's own loader, re-exports it with the app's own exporter, and
    /// byte-compares against the committed oracle. Tests "is the oracle a function of the file", which regenerating
    /// the set does not — regeneration makes new layers, and new adjustment layers pick new noise seeds.
    @Test(.enabled(if: verifyPath != nil)) func committedOraclesReproduceFromTheirDocuments() async throws {
        let root = URL(fileURLWithPath: try #require(Self.verifyPath))
        let index = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("index.json"))) as? [[String: Any]])
        var same = 0, differ: [String] = []
        for e in index {
            let group = e["group"] as! String, name = e["name"] as! String
            let snapshot = try await ProjectStore.shared.load(from: root.appendingPathComponent("\(group)/\(name).comp"))
            let png = try await ImageExporter.shared.pngData(snapshot)
            let stored = try Data(contentsOf: root.appendingPathComponent(e["oracle"] as! String))
            if png == stored { same += 1 } else { differ.append("\(group)/\(name)") }
        }
        print("ORACLE_REPRODUCIBLE \(same)/\(index.count) differ: \(differ.isEmpty ? "none" : differ.joined(separator: ", "))")
        #expect(differ.isEmpty)
    }

    // MARK: latency subject (gate 2) — never committed; ~1 GB of layer PNGs

    static let largePath = ProcessInfo.processInfo.environment["COMP_FIXTURE_LARGE"]

    private func bigImage(_ w: Int, _ h: Int, _ f: (Double, Double) -> (Double, Double, Double, Double)) throws -> ImportedImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let px = try #require(ctx.data).assumingMemoryBound(to: UInt8.self)
        for y in 0..<h { for x in 0..<w {
            let (r, g, b, a) = f(Double(x) / Double(w - 1), Double(y) / Double(h - 1)); let i = (y * w + x) * 4
            px[i] = UInt8((r * a * 255).rounded()); px[i+1] = UInt8((g * a * 255).rounded())
            px[i+2] = UInt8((b * a * 255).rounded()); px[i+3] = UInt8((a * 255).rounded())
        } }
        let img = try #require(ctx.makeImage())
        return ImportedImage(image: img, thumbnail: img, name: "Large")
    }

    /// Latency subjects — as large as the .comp format allows. It caps a document at 100 MP of layer pixels in
    /// total (`ProjectStore.checkSize`), so a 24 MP document holds at most 4 full-canvas layers.
    static let latencySubjects: [(name: String, w: Int, h: Int, layers: Int)] = [
        ("latency-24mp-4layers", 6000, 4000, 4),
        ("latency-4k-10layers", 3840, 2560, 10),
    ]

    @Test(.enabled(if: largePath != nil)) func writeTheLatencySubjects() async throws {
        let root = URL(fileURLWithPath: try #require(Self.largePath))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var facts: [[String: Any]] = []
        for subject in Self.latencySubjects {
            let (w, h) = (subject.w, subject.h)
            let s = EditorSession(); s.createDocument(width: w, height: h)
            s.insert(try bigImage(w, h) { x, y in (x, y, 0.5, 1) })                                       // backdrop
            let modes: [LayerBlendMode] = [.multiply, .screen, .overlay, .softLight, .colorDodge, .linearBurn, .hue]
            let structure = subject.layers >= 6          // room for a folder + clip stack at the end
            let plain = subject.layers - 1 - (structure ? 2 : 0)
            for i in 0..<plain {
                let k = Double(i) / Double(max(1, plain))
                s.insert(try bigImage(w, h) { x, y in (fmod(x + k, 1), 1 - y, fmod(y + k, 1), x > 0.8 ? 0.6 : 1) })
                s.setLayerBlendMode(modes[i % modes.count])
                if i == 1 { s.setSelection(ellipse(w, h), name: "Ellipse"); s.addMask(); s.setSelection(nil, name: "Deselect") }
            }
            if structure {
                s.addGroup(); s.setLayerOpacity(0.7)                                                     // folder at 70%
                s.insert(try bigImage(w, h) { x, y in hypot(x - 0.5, y - 0.5) < 0.3 ? (0.9, 0.4, 0.1, 1) : (0, 0, 0, 0) })
                s.insert(try bigImage(w, h) { x, y in (y, x, 1 - x, 1) }); s.setLayerBlendMode(.multiply)
                let clipped = try #require(s.activeLayerID); s.toggleClippingMask(clipped)                 // clip stack
            }
            let snapshot = try #require(s.projectSnapshot())
            let pixelLayers = snapshot.manifest.layers.filter { $0.imageFile != nil }.count
            #expect(pixelLayers == subject.layers, "\(subject.name): \(pixelLayers) pixel layers, wanted \(subject.layers)")
            let url = root.appendingPathComponent("\(subject.name).comp")
            try? FileManager.default.removeItem(at: url)
            try await ProjectStore.shared.save(snapshot, to: url)
            var times: [Double] = []
            for _ in 0..<3 {
                let t0 = Date(); _ = try await ImageExporter.shared.render(snapshot)
                times.append(Date().timeIntervalSince(t0) * 1000)
            }
            times.sort()
            facts.append(["name": subject.name, "width": w, "height": h, "pixelLayers": pixelLayers,
                          "oracleRenderMs": times, "oracleMedianMs": times[1]])
            print("LATENCY_SUBJECT \(subject.name) oracle median \(Int(times[1])) ms")
        }
        try JSONSerialization.data(withJSONObject: facts, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("latency.json"))
    }

    private func ellipse(_ w: Int, _ h: Int) -> DocumentSelection {
        DocumentSelection(path: CGPath(ellipseIn: CGRect(x: Double(w) * 0.2, y: Double(h) * 0.2, width: Double(w) * 0.6,
                                                         height: Double(h) * 0.6), transform: nil), antialiased: true, feather: 40)
    }
}
