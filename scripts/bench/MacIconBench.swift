import AppKit
import Darwin
import Observation
import SwiftUI

enum IconProbe {
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    static func cpu() -> UInt64 { clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) }
    static func wall() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    static func median(_ values: [UInt64]) -> UInt64 {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }
}

enum IconSet {
    static let popover: [Provider] = [.claude, .openai, .grok, .grokBot, .cursor, .copilot, .antigravity]
    static let presentSizes: [CGFloat] = [20, 26, 28, 40]
    static let pixelSizes: [CGFloat] = [18, 20, 22, 26, 28, 32, 40]
    static let glyphSize: CGFloat = 17.22

    static func providers(_ name: String) -> [Provider] {
        switch name {
        case "popover": popover
        case "all": Provider.allCases
        default: name.split(separator: ",").compactMap { Provider(rawValue: String($0)) }
        }
    }

    static var assetNames: [String] {
        var seen = Set<String>()
        return Provider.allCases.compactMap(\.assetName).filter { seen.insert($0).inserted }
    }

    static var glyphNames: [String] {
        var seen = Set<String>()
        return Provider.allCases.compactMap(\.menuGlyphName).filter { seen.insert($0).inserted }
    }
}

@Observable
@MainActor
final class IconSheetModel {
    var shows = false
    var generation = 0
    var tick = 0
}

struct IconBoard: View {
    var providers: [Provider]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                ForEach(providers, id: \.self) { provider in
                    ProviderGlyph(provider: provider, size: IconSet.glyphSize)
                }
            }
            .foregroundStyle(.primary)
            ForEach(providers, id: \.self) { provider in
                HStack(spacing: 8) {
                    ForEach(IconSet.presentSizes, id: \.self) { size in
                        ProviderMark(provider: provider, size: size)
                    }
                }
            }
        }
    }
}

struct IconSheet: View {
    let model: IconSheetModel
    var providers: [Provider]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(model.tick)")
                .font(.system(size: 11).monospacedDigit())
            if model.shows {
                IconBoard(providers: providers)
                    .id(model.generation)
            }
        }
        .padding(8)
        .frame(width: 420, height: 940, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

@main
@MainActor
enum MacIconBench {
    static func value(_ flag: String, default fallback: String) -> String {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return fallback }
        return arguments[index + 1]
    }

    static func main() {
        let mode = CommandLine.arguments.dropFirst().first ?? "present"
        switch mode {
        case "reps": reps()
        case "lookup": lookup()
        case "present": present()
        case "pixels": pixels()
        case "compare": compare()
        default:
            print("modes: reps, lookup, present, pixels --out <folder>, compare <a> <b>")
            exit(2)
        }
    }

    static func describe(_ image: NSImage) -> String {
        let reps = image.representations.map { rep in
            "\(type(of: rep)) \(rep.pixelsWide)x\(rep.pixelsHigh)px \(Int(rep.size.width))x\(Int(rep.size.height))pt"
        }
        return "size=\(Int(image.size.width))x\(Int(image.size.height)) template=\(image.isTemplate) reps=[\(reps.joined(separator: "; "))]"
    }

    static func reps() {
        for name in IconSet.assetNames {
            print(name, IconSource.image(name, template: false).map(describe) ?? "missing")
        }
        for name in IconSet.glyphNames {
            print(name, "(template)", IconSource.image(name, template: true).map(describe) ?? "missing")
        }
    }

    static func drawing(_ image: NSImage, into rep: NSBitmapImageRep) {
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: 40, height: 40), from: .zero, operation: .sourceOver, fraction: 1)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
    }

    static func lookup() {
        let rounds = Int(value("--rounds", default: "400")) ?? 400
        let canvas = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 80, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        canvas.size = NSSize(width: 40, height: 40)
        let entries = IconSet.assetNames.map { ($0, false) } + IconSet.glyphNames.map { ($0, true) }
        print("row,name,template,first_lookup_ns,first_draw_ns,warm_lookup_ns,warm_lookup_draw_ns")
        let before = IconProbe.footprint()
        var firstLookups: UInt64 = 0
        var firstDraws: UInt64 = 0
        var warmLookups: UInt64 = 0
        var warmDraws: UInt64 = 0
        for (name, template) in entries {
            let start = IconProbe.wall()
            let image = IconSource.image(name, template: template)
            let found = IconProbe.wall()
            if let image { drawing(image, into: canvas) }
            let drawn = IconProbe.wall()
            var lookups: [UInt64] = []
            var draws: [UInt64] = []
            for _ in 0..<rounds {
                autoreleasepool {
                    let began = IconProbe.wall()
                    let again = IconSource.image(name, template: template)
                    lookups.append(IconProbe.wall() - began)
                    _ = again
                }
            }
            for _ in 0..<(rounds / 8) {
                autoreleasepool {
                    let began = IconProbe.wall()
                    if let again = IconSource.image(name, template: template) { drawing(again, into: canvas) }
                    draws.append(IconProbe.wall() - began)
                }
            }
            let warm = IconProbe.median(lookups)
            let warmDraw = IconProbe.median(draws)
            firstLookups += found - start
            firstDraws += drawn - found
            warmLookups += warm
            warmDraws += warmDraw
            print("icon,\(name),\(template),\(found - start),\(drawn - found),\(warm),\(warmDraw)")
        }
        let after = IconProbe.footprint()
        print("total,\(entries.count) names,,\(firstLookups),\(firstDraws),\(warmLookups),\(warmDraws)")
        print("footprint_kb,before=\(before / 1024),after=\(after / 1024),delta=\((Int64(after) - Int64(before)) / 1024)")
    }

    static func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        CATransaction.flush()
    }

    static func present() {
        let set = value("--set", default: "all")
        let generations = Int(value("--generations", default: "20")) ?? 20
        let ticks = Int(value("--ticks", default: "20")) ?? 20
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let model = IconSheetModel()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 940), styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.alphaValue = CGFloat(Double(value("--alpha", default: "0.01")) ?? 0.01)
        window.contentView = NSHostingView(rootView: IconSheet(model: model, providers: IconSet.providers(set)))
        window.orderFrontRegardless()
        spin(0.6)

        let idle = (IconProbe.footprint(), IconProbe.cpu(), IconProbe.wall())
        model.shows = true
        window.displayIfNeeded()
        CATransaction.flush()
        let shown = IconProbe.wall()
        spin(0.5)
        let cold = (IconProbe.footprint(), IconProbe.cpu())

        var peak = cold.0
        for generation in 1...max(generations, 1) {
            model.generation = generation
            spin(0.04)
            peak = max(peak, IconProbe.footprint())
        }
        spin(0.3)
        let churned = (IconProbe.footprint(), IconProbe.cpu())

        for tick in 1...max(ticks, 1) {
            model.tick = tick
            spin(0.04)
        }
        spin(0.3)
        let ticked = (IconProbe.footprint(), IconProbe.cpu())

        let scale = window.backingScaleFactor
        func kb(_ bytes: UInt64) -> Int64 { Int64(bytes) / 1024 }
        func ms(_ nanos: UInt64) -> String { String(format: "%.3f", Double(nanos) / 1_000_000) }
        print("set,scale,first_show_wall_ms,cold_cpu_ms,cold_footprint_kb,churn_cpu_ms_per_generation,churn_footprint_kb,churn_peak_kb,tick_cpu_ms_per_tick,final_footprint_kb")
        print([
            set,
            "\(scale)",
            ms(shown - idle.2),
            ms(cold.1 - idle.1),
            "\(kb(cold.0) - kb(idle.0))",
            ms((churned.1 - cold.1) / UInt64(max(generations, 1))),
            "\(kb(churned.0) - kb(idle.0))",
            "\(kb(peak) - kb(idle.0))",
            ms((ticked.1 - churned.1) / UInt64(max(ticks, 1))),
            "\(kb(ticked.0))",
        ].joined(separator: ","))
        window.orderOut(nil)
    }

    static func capture<Content: View>(_ view: Content, side: CGFloat, scale: CGFloat, dark: Bool) -> NSBitmapImageRep? {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: view
            .environment(\.displayScale, scale)
            .frame(width: side, height: side)
            .background(Color(nsColor: .windowBackgroundColor)))
        hosting.appearance = appearance
        let size = NSSize(width: side, height: side)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int((side * scale).rounded()), pixelsHigh: Int((side * scale).rounded()),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep
    }

    static func pixels() {
        let output = URL(fileURLWithPath: value("--out", default: "icon-pixels"), isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        var written = 0
        func save(_ rep: NSBitmapImageRep?, _ name: String) {
            guard let data = rep?.representation(using: .png, properties: [:]) else { return }
            try? data.write(to: output.appendingPathComponent(name))
            written += 1
        }
        for dark in [false, true] {
            for scale in [CGFloat(1), 2] {
                let suffix = "@\(Int(scale))x-\(dark ? "dark" : "light").png"
                for provider in Provider.allCases {
                    for size in IconSet.pixelSizes {
                        let padded = size + 8
                        save(capture(ProviderMark(provider: provider, size: size), side: padded, scale: scale, dark: dark),
                             "mark-\(provider.rawValue)-\(Int(size))\(suffix)")
                    }
                    let glyph = ProviderGlyph(provider: provider, size: IconSet.glyphSize).foregroundStyle(.primary)
                    save(capture(glyph, side: 24, scale: scale, dark: dark), "glyph-\(provider.rawValue)\(suffix)")
                }
            }
        }
        print("wrote \(written) images to \(output.path)")
    }

    static func bytes(_ url: URL) -> (width: Int, height: Int, data: [UInt8])? {
        guard let data = try? Data(contentsOf: url), let rep = NSBitmapImageRep(data: data),
              let image = rep.cgImage else { return nil }
        let width = image.width
        let height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &buffer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (width, height, buffer)
    }

    static func compare() {
        let arguments = Array(CommandLine.arguments.dropFirst(2))
        guard arguments.count >= 2 else {
            print("compare <folder a> <folder b>")
            exit(2)
        }
        let left = URL(fileURLWithPath: arguments[0], isDirectory: true)
        let right = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: left.path)) ?? []).filter { $0.hasSuffix(".png") }.sorted()
        var identical = 0
        var worst = 0
        var missing = 0
        print("file,pixels,differing_pixels,max_channel_delta,mean_channel_delta")
        for name in names {
            guard let a = bytes(left.appendingPathComponent(name)), let b = bytes(right.appendingPathComponent(name)),
                  a.width == b.width, a.height == b.height else {
                missing += 1
                print("\(name),,,missing or resized,")
                continue
            }
            var differing = 0
            var largest = 0
            var sum = 0
            for pixel in 0..<(a.width * a.height) {
                var changed = false
                for channel in 0..<4 {
                    let delta = abs(Int(a.data[pixel * 4 + channel]) - Int(b.data[pixel * 4 + channel]))
                    if delta > 0 { changed = true }
                    largest = max(largest, delta)
                    sum += delta
                }
                if changed { differing += 1 }
            }
            if differing == 0 {
                identical += 1
            } else {
                let mean = Double(sum) / Double(a.width * a.height * 4)
                print("\(name),\(a.width * a.height),\(differing),\(largest),\(String(format: "%.4f", mean))")
            }
            worst = max(worst, largest)
        }
        print("summary,files=\(names.count),identical=\(identical),different=\(names.count - identical - missing),missing=\(missing),max_channel_delta=\(worst)")
    }
}
