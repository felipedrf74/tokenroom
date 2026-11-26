import XCTest
@testable import Tokenroom

final class ProviderIconTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TokenroomImage.forgetIcons()
    }

    private var iconNames: [String] {
        Array(Set(Provider.allCases.compactMap(\.assetName)))
    }

    private var glyphNames: [String] {
        Array(Set(Provider.allCases.compactMap(\.menuGlyphName)))
    }

    private func longestPixels(_ image: NSImage) -> Int {
        image.representations.map { max($0.pixelsWide, $0.pixelsHigh) }.max() ?? 0
    }

    private func drawn(_ image: NSImage, side: Int = 80) throws -> [UInt8] {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32
        ))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return Array(UnsafeBufferPointer(start: try XCTUnwrap(rep.bitmapData), count: side * side * 4))
    }

    private func solid(_ color: NSColor, width: Int, height: Int) throws -> NSImage {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        color.setFill()
        NSRect(x: 0, y: 0, width: width / 2, height: height).fill()
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        return image
    }

    func testAnIconIsFoundOnceAndKept() throws {
        for name in iconNames {
            let first = try XCTUnwrap(TokenroomImage.icon(name), name)
            XCTAssertTrue(first === TokenroomImage.icon(name), "\(name) is looked up again")
            XCTAssertFalse(first.isTemplate, name)
        }
        TokenroomImage.forgetIcons()
        XCTAssertNotNil(TokenroomImage.icon(iconNames[0]), "An emptied cache finds the icon again")
    }

    func testATemplateAndItsColouredIconAreKeptApart() throws {
        let glyph = try XCTUnwrap(TokenroomImage.template("ProviderCopilot"))
        let mark = try XCTUnwrap(TokenroomImage.icon("ProviderCopilot"))
        XCTAssertFalse(glyph === mark)
        XCTAssertTrue(glyph.isTemplate)
        XCTAssertFalse(mark.isTemplate)
        XCTAssertTrue(try XCTUnwrap(TokenroomImage.template("ProviderCopilot")).isTemplate, "Finding the mark leaves the glyph a template")
        XCTAssertTrue(glyph === TokenroomImage.template("ProviderCopilot"))
        for name in glyphNames {
            XCTAssertEqual(TokenroomImage.template(name)?.isTemplate, true, name)
        }
    }

    func testEveryIconAndGlyphFitsInTheCache() {
        XCTAssertLessThanOrEqual((iconNames.count + glyphNames.count) * 2, TokenroomImage.iconCountLimit)
    }

    func testALargeBitmapIsFittedToTheSizeIconsAreShownAt() throws {
        let limit = Int(TokenroomImage.iconSide * TokenroomImage.iconScale)
        for name in ["ProviderAntigravity", "ProviderMoonshot"] {
            let whole = try XCTUnwrap(TokenroomImage.named(name))
            XCTAssertGreaterThan(longestPixels(whole), TokenroomImage.iconPixelLimit, "\(name) ships larger than it is shown")
            let icon = try XCTUnwrap(TokenroomImage.icon(name))
            XCTAssertEqual(longestPixels(icon), limit, name)
            XCTAssertEqual(max(icon.size.width, icon.size.height), TokenroomImage.iconSide, name)
            XCTAssertEqual(icon.size.width / icon.size.height, whole.size.width / whole.size.height, accuracy: 0.01, name)
            XCTAssertEqual(icon.representations.count, 1, name)
        }
        for name in iconNames {
            let icon = try XCTUnwrap(TokenroomImage.icon(name))
            XCTAssertLessThanOrEqual(longestPixels(icon), TokenroomImage.iconPixelLimit, "\(name) is kept larger than any icon is shown")
        }
    }

    func testAnIconAlreadyAtItsSizeKeepsEveryRepresentation() throws {
        for name in ["ProviderClaude", "ProviderBuild", "ProviderCursor", "GlyphBot"] {
            let whole = try XCTUnwrap(TokenroomImage.named(name))
            let icon = try XCTUnwrap(TokenroomImage.icon(name))
            XCTAssertEqual(icon.size, whole.size, name)
            XCTAssertEqual(icon.representations.map(\.pixelsWide), whole.representations.map(\.pixelsWide), name)
            XCTAssertGreaterThan(Set(icon.representations.map(\.pixelsWide)).count, 1, "\(name) keeps its 1x and 2x")
            XCTAssertEqual(try drawn(icon), try drawn(whole), "\(name) draws as it did")
        }
    }

    func testTheLargeArtIsLeftAsItIs() throws {
        let art = try XCTUnwrap(TokenroomImage.named("NewsEditorialArt"))
        XCTAssertEqual(longestPixels(art), 1448)
        XCTAssertEqual(art.size, NSSize(width: 1086, height: 1448))
        XCTAssertGreaterThan(longestPixels(try XCTUnwrap(TokenroomImage.named("ProviderAntigravity"))), 500, "named still gives the whole image")
    }

    func testFittingKeepsShapeColourAndTransparency() throws {
        let wide = try solid(NSColor(deviceRed: 0.2, green: 0.6, blue: 0.9, alpha: 1), width: 600, height: 300)
        let fitted = TokenroomImage.fitted(wide)
        XCTAssertEqual(fitted.size, NSSize(width: 64, height: 32))
        let rep = try XCTUnwrap(fitted.representations.first as? NSBitmapImageRep)
        XCTAssertEqual([rep.pixelsWide, rep.pixelsHigh], [128, 64])
        let painted = try XCTUnwrap(rep.colorAt(x: 20, y: 32)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(painted.redComponent, 0.2, accuracy: 0.02)
        XCTAssertEqual(painted.greenComponent, 0.6, accuracy: 0.02)
        XCTAssertEqual(painted.blueComponent, 0.9, accuracy: 0.02)
        XCTAssertEqual(painted.alphaComponent, 1, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(rep.colorAt(x: 108, y: 32)).alphaComponent, 0, accuracy: 0.01)

        let small = try solid(.red, width: 256, height: 256)
        let kept = TokenroomImage.fitted(small)
        XCTAssertEqual(longestPixels(kept), 256, "An image at the limit is not redrawn")
        XCTAssertFalse(kept === small, "The caller gets its own image, whose template flag is its own")
    }

    func testAFittedIconDrawsLikeTheWholeImage() throws {
        for name in iconNames {
            let whole = try drawn(try XCTUnwrap(TokenroomImage.named(name)))
            let icon = try drawn(try XCTUnwrap(TokenroomImage.icon(name)))
            let total = zip(whole, icon).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
            XCTAssertLessThan(Double(total) / Double(whole.count), 6, "\(name) no longer looks like its image")
        }
    }

    func testIconsFromAnotherBundleAreItsOwn() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TokenroomIcons-\(UUID().uuidString).bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        for (file, side) in [("ProviderClaude.png", 8), ("ProviderClaude@2x.png", 16), ("Large.png", 600)] {
            let rep = try XCTUnwrap(try solid(.red, width: side, height: side).representations.first as? NSBitmapImageRep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(file))
        }
        let bundle = try XCTUnwrap(Bundle(url: folder))
        let injected = try XCTUnwrap(TokenroomImage.icon("ProviderClaude", bundle: bundle))
        XCTAssertEqual(injected.size, NSSize(width: 8, height: 8))
        XCTAssertEqual(injected.representations.map(\.pixelsWide), [8, 16])
        XCTAssertTrue(injected === TokenroomImage.icon("ProviderClaude", bundle: bundle))
        let app = try XCTUnwrap(TokenroomImage.icon("ProviderClaude"))
        XCTAssertEqual(app.size, NSSize(width: 32, height: 32), "The app's icon is not the other bundle's")
        XCTAssertEqual(TokenroomImage.named("ProviderClaude", bundle: bundle)?.size, NSSize(width: 8, height: 8))
        XCTAssertEqual(longestPixels(try XCTUnwrap(TokenroomImage.icon("Large", bundle: bundle))), 128)
        XCTAssertNil(TokenroomImage.icon("ProviderMoonshot", bundle: bundle), "A bundle without the icon does not get the app's")
        XCTAssertNil(TokenroomImage.icon("Missing"))
    }

    func testEveryNamedIconShips() {
        for provider in Provider.allCases {
            guard let name = provider.assetName else { continue }
            XCTAssertNotNil(TokenroomImage.named(name), "\(provider.rawValue): \(name) isn't in the app")
        }
    }

    func testProvidersWithoutAnIconAreTheOnesWaitingOnTheirOwners() {
        XCTAssertEqual(Set(Provider.allCases.filter { $0.assetName == nil }), [.xaiOrg])
    }

    func testGrokAndCopilotShowTheirOwnIcons() {
        XCTAssertEqual(Provider.grok.assetName, "ProviderBuild")
        XCTAssertEqual(Provider.grokBot.assetName, "ProviderBot")
        XCTAssertFalse(Provider.grokBot.iconIsMark, "Grok Bot's is an app icon, drawn as it is")
        XCTAssertEqual(Provider.copilot.assetName, "ProviderCopilot")
        XCTAssertTrue(Provider.copilot.iconIsMark, "GitHub's Copilot mark sits on a white tile")
    }

    func testOnlyMarksWithoutASquareGetATile() {
        XCTAssertFalse(Provider.claude.iconIsMark, "App icons are drawn as they are")
        XCTAssertFalse(Provider.devin.iconIsMark, "Devin's mark comes on its own square")
        XCTAssertTrue(Provider.deepseek.iconIsMark)
        XCTAssertTrue(Provider.anthropicOrg.iconIsMark)
    }
}
