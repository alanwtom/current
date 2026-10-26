import XCTest
import CurrentCore
@testable import CurrentApp

@MainActor
final class FileTreeEditorTests: XCTestCase {
    func testBulkPriorityKeepsOtherFilesAndUpdatesParentFolders() {
        let files = [
            FileInfo(pathComponents: ["Pack", "Chapter 1", "a.jpg"], size: 10),
            FileInfo(pathComponents: ["Pack", "Chapter 1", "b.jpg"], size: 20),
            FileInfo(pathComponents: ["Pack", "Chapter 2", "c.jpg"], size: 30),
            FileInfo(pathComponents: ["readme.txt"], size: 1),
        ]
        let original = FileTreeBuilder.build(from: files)
        let changed = FileTreeEditor.settingPriority(
            original,
            ids: ["root/Pack/Chapter 1", "root/Pack/Chapter 1/a.jpg", "root/Pack/Chapter 2/c.jpg"],
            priority: .skip
        )
        XCTAssertEqual(FileTreeBuilder.flattenPriorities(changed), [.skip, .skip, .skip, .normal])
        XCTAssertEqual(changed.first { $0.name == "Pack" }?.priority, .skip)
        XCTAssertEqual(FileTreeBuilder.selectedBytes(changed), 1)
        XCTAssertEqual(FileTreeBuilder.selectedBytes(original), 61)
    }

    func testLargeBulkEditUsesOneTreePass() {
        let files = (0..<5_000).map {
            FileInfo(pathComponents: ["Pack", "page \($0).jpg"], size: 1)
        }
        let tree = FileTreeBuilder.build(from: files)
        let selected = Set((0..<1_000).map { "root/Pack/page \($0).jpg" })
        let startedOld = Date.timeIntervalSinceReferenceDate
        var repeated = tree
        for id in selected {
            repeated = FileTreeEditor.settingPriority(repeated, id: id, priority: .skip)
        }
        let oldSeconds = Date.timeIntervalSinceReferenceDate - startedOld
        let startedNew = Date.timeIntervalSinceReferenceDate
        let bulk = FileTreeEditor.settingPriority(tree, ids: selected, priority: .skip)
        let newSeconds = Date.timeIntervalSinceReferenceDate - startedNew
        XCTAssertEqual(FileTreeBuilder.flattenPriorities(bulk), FileTreeBuilder.flattenPriorities(repeated))
        XCTAssertEqual(FileTreeBuilder.selectedBytes(bulk), 4_000)
        print("Bulk priority benchmark: repeated=\(oldSeconds)s, single pass=\(newSeconds)s")
    }
}
