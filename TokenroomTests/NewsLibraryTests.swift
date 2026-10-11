import XCTest
import SwiftUI
import AppKit
@testable import Tokenroom

@MainActor final class NewsLibraryTests: XCTestCase {
    func testEverySuccessfulSaveCanBeReopenedWithinFileLimit() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        var written = Data()
        let library = NewsLibrary(directory: directory, writer: { data, _ in written = data })
        var rejected = false
        for index in 0..<470 {
            var item = bookmark("large-\(index)")
            item.title = String(repeating: "a", count: 9000)
            if !library.save(item) { rejected = true; break }
        }
        XCTAssertTrue(rejected, "Reject a candidate before it exceeds the loader's byte limit")
        XCTAssertLessThanOrEqual(written.count, 4 * 1024 * 1024)
        XCTAssertNotNil(library.problem)
        try written.write(to: directory.appendingPathComponent(NewsLibrary.fileName))
        let reopened = NewsLibrary(directory: directory)
        XCTAssertEqual(reopened.saved.count, library.saved.count)
        XCTAssertNil(reopened.problem)
    }
    func testAliasMergeCannotWriteAnUnreadableBookmark() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let library = NewsLibrary(directory: directory)
        XCTAssertTrue(library.save(bookmark("a", aliases: Set((0..<100).map { "alias-\($0)" }))))
        XCTAssertFalse(library.save(bookmark("a", aliases: ["new-alias"])))
        XCTAssertEqual(NewsLibrary(directory: directory).saved, library.saved)
        XCTAssertNotNil(library.problem)
    }
    func testOpeningSavedDetailMarksItsFeedAliasesRead() {
        let library = NewsLibrary(directory: nil)
        let item = bookmark("saved", aliases: ["source|original"])
        XCTAssertTrue(library.save(item))
        XCTAssertFalse(library.isRead(id: "source|original"))
        let hosting = NSHostingView(rootView: NewsSavedDetail(item: item, library: library))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(library.isRead(id: "source|original"))
        window.orderOut(nil)
    }
    func bookmark(_ id: String, aliases: Set<String> = [], date: Date = Date(timeIntervalSince1970: 10)) -> NewsBookmark {
        .init(id: id, aliases: aliases, kind: .story, title: "Saved story", publisher: "Official feed", url: URL(string: "https://example.com/story"), summary: nil, publishedAt: nil, updatedAt: nil, savedAt: date)
    }
    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func testRepeatedSavePreservesDateAndSurvivesFeedTurnover() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let library = NewsLibrary(directory: directory)
        XCTAssertTrue(library.save(bookmark("a")))
        XCTAssertTrue(library.save(bookmark("a", date: Date(timeIntervalSince1970: 20))))
        XCTAssertEqual(library.saved.first?.savedAt, Date(timeIntervalSince1970: 10))
        let reopened = NewsLibrary(directory: directory)
        XCTAssertEqual(reopened.saved.count, 1)
        XCTAssertEqual(reopened.saved.first?.title, "Saved story")
    }
    func testWinnerAliasesRetainSavedAndReadState() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let library = NewsLibrary(directory: directory)
        XCTAssertTrue(library.save(bookmark("first", aliases: ["tool|a", "tool-releases|b"])))
        library.markRead(id: "first", aliases: ["tool|a"])
        XCTAssertTrue(library.isSaved(id: "second", aliases: ["tool-releases|b"]))
        XCTAssertTrue(library.isRead(id: "second", aliases: ["tool|a"]))
    }
    func testCapacityDoesNotEvictAndExcerptsAreBounded() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let library = NewsLibrary(directory: directory)
        var item = bookmark("first"); item.summary = String(repeating: "a", count: 2100)
        XCTAssertTrue(library.save(item))
        for n in 1..<500 { XCTAssertTrue(library.save(bookmark(String(n)))) }
        XCTAssertFalse(library.save(bookmark("overflow")))
        XCTAssertEqual(library.saved.count, 500)
        XCTAssertEqual(library.saved.first { $0.id == "first" }?.summary?.count, 2000)
        XCTAssertNotNil(library.problem)
    }
    func testRemoveRestoreUndo() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let library = NewsLibrary(directory: directory)
        _ = library.save(bookmark("a"))
        let removed = try XCTUnwrap(library.remove(id: "a"))
        XCTAssertTrue(library.saved.isEmpty)
        XCTAssertTrue(library.restore(removed))
        XCTAssertEqual(library.saved, [removed])
    }
    func testWriteFailureKeepsLastValidState() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        _ = NewsLibrary(directory: directory).save(bookmark("a"))
        let library = NewsLibrary(directory: directory, writer: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        XCTAssertFalse(library.save(bookmark("b")))
        XCTAssertEqual(library.saved.map(\.id), ["a"])
        XCTAssertNil(library.remove(id: "a"))
        XCTAssertNotNil(library.problem)
    }
    func testCorruptAndUnsupportedFilesArePreserved() throws {
        for bytes in [Data("broken".utf8), Data("{\"version\":999,\"saved\":[],\"read\":[]}".utf8)] {
            let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent(NewsLibrary.fileName)
            try bytes.write(to: file)
            let library = NewsLibrary(directory: directory)
            XCTAssertNotNil(library.problem)
            XCTAssertFalse(library.save(bookmark("a")))
            library.markRead(id: "a", aliases: [])
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
    }
}
