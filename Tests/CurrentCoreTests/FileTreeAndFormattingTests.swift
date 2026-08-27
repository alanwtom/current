import XCTest
@testable import CurrentCore

final class FileTreeTests: XCTestCase {

    private let files: [FileInfo] = [
        FileInfo(pathComponents: ["movie.mkv"], size: 8_000_000_000),
        FileInfo(pathComponents: ["extras", "trailer.mp4"], size: 300_000_000),
        FileInfo(pathComponents: ["extras", "cover.jpg"], size: 2_000_000),
    ]

    func testBuildsHierarchyFromFlatList() {
        let nodes = FileTreeBuilder.build(from: files)
        XCTAssertEqual(nodes.count, 2)

        let extras = nodes.first { $0.name == "extras" }
        XCTAssertNotNil(extras)
        XCTAssertEqual(extras?.children.count, 2)
        XCTAssertEqual(extras?.size, 302_000_000)
    }

    func testFolderSelectionAggregatesChildren() {
        var nodes = FileTreeBuilder.build(from: files)

        let extrasID = "root/extras"
        nodes = FileTreeBuilder.setSelection(nodes, id: extrasID, selected: false)

        XCTAssertEqual(
            FileTreeBuilder.selectionState(of: nodes.first { $0.id == extrasID }!),
            .none
        )
        // Root movie file untouched.
        let movie = nodes.first { $0.name == "movie.mkv" }!
        XCTAssertEqual(FileTreeBuilder.selectionState(of: movie), .all)

        // Selected bytes exclude the skipped folder.
        let expected = Int64(8_000_000_000)
        XCTAssertEqual(FileTreeBuilder.selectedBytes(nodes), expected)
    }

    func testFlattenPrioritiesAlignsWithEngineIndices() {
        var nodes = FileTreeBuilder.build(from: files)
        nodes = FileTreeBuilder.setSelection(nodes, id: "root/extras", selected: false)

        let priorities = FileTreeBuilder.flattenPriorities(nodes)
        XCTAssertEqual(priorities.count, 3)
        XCTAssertEqual(priorities[0], .normal)   // movie.mkv
        XCTAssertEqual(priorities[1], .skip)     // trailer
        XCTAssertEqual(priorities[2], .skip)     // cover
    }

    func testSearchFiltersLeavesAndKeepsAncestors() {
        let nodes = FileTreeBuilder.build(from: files)
        let filtered = FileTreeBuilder.filtered(nodes, query: "trailer")
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.name, "extras")
        XCTAssertEqual(filtered.first?.children.first?.name, "trailer.mp4")
    }

    func testLeafCount() {
        let nodes = FileTreeBuilder.build(from: files)
        XCTAssertEqual(FileTreeBuilder.leafCount(nodes), 3)
    }

    func testPartialFolderShowsMixedState() {
        var nodes = FileTreeBuilder.build(from: files)
        nodes = FileTreeBuilder.setSelection(nodes, id: "root/extras/trailer.mp4", selected: false)

        let extras = nodes.first { $0.name == "extras" }!
        XCTAssertEqual(FileTreeBuilder.selectionState(of: extras), .partial)
    }
}

final class FormattingTests: XCTestCase {

    func testBytesFormatting() {
        XCTAssertEqual(ByteFormatting.bytes(0), "0 B")
        XCTAssertEqual(ByteFormatting.bytes(999), "999 B")
        XCTAssertEqual(ByteFormatting.bytes(1_500), "1.5 KB")
        XCTAssertEqual(ByteFormatting.bytes(Int64(8.4 * 1024 * 1024 * 1024)), "8.4 GB")
        XCTAssertEqual(ByteFormatting.bytes(11_200_000_000, precision: 1), "10.4 GB")
    }

    func testRateFormatting() {
        XCTAssertEqual(ByteFormatting.rate(0), "—")
        XCTAssertTrue(ByteFormatting.rate(18_700_000).hasSuffix("MB/s"))
    }

    func testEtaFormatting() {
        XCTAssertEqual(ByteFormatting.eta(nil), "—")
        XCTAssertEqual(ByteFormatting.eta(45), "45s")
        XCTAssertEqual(ByteFormatting.eta(180), "3 min")
        XCTAssertEqual(ByteFormatting.eta(3600 * 2 + 1800), "2.5 hr")
        XCTAssertEqual(ByteFormatting.eta(3600 * 24 * 3 + 3600 * 6), "3d 6h")
    }

    func testDurationLongForm() {
        XCTAssertEqual(ByteFormatting.duration(3600 * 54 + 3600 * 6), "2d 12h")
        XCTAssertEqual(ByteFormatting.duration(3600 * 24 * 2 + 3600 * 6), "2d 6h")
        XCTAssertEqual(ByteFormatting.duration(86_400), "1d")
    }

    func testRatio() {
        XCTAssertEqual(ByteFormatting.ratio(1.24), "1.24×")
        XCTAssertEqual(ByteFormatting.ratio(.infinity), "∞")
    }

    func testProgress() {
        XCTAssertEqual(ByteFormatting.progress(0.723), "72%")
    }
}
