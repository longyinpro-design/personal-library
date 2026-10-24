import Foundation
import Testing
@testable import LibraryCore

@Suite(.serialized)
final class LibraryRuleTests {
    private var temporary: URL!
    private var root: URL { temporary.appendingPathComponent("Library") }

    init() throws {
        temporary = testTemporaryDirectory.appendingPathComponent("rules-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: temporary) }

    private func write(_ name: String, _ text: String) throws -> URL {
        let url = temporary.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: 匹配

    @Test func theFirstEnabledRuleThatMatchesWins() {
        let rules = [
            LibraryRule(match: "发票", tags: ["财务"]),
            LibraryRule(match: "合同", tags: ["法务"]),
            LibraryRule(match: "合同 2026", tags: ["年度"], isEnabled: false)
        ]
        let hit = LibraryRules.match(for: "2026合同.docx", in: rules)
        #expect(hit?.tags == ["法务"])
        #expect(LibraryRules.match(for: "扫描件.pdf", in: rules) == nil)
    }

    @Test func matchingIgnoresCaseAndWidthAndTrims() {
        let rules = [LibraryRule(match: "Ｃontract", tags: ["法务"])]
        #expect(LibraryRules.match(for: "contract-2026.pdf", in: rules)?.match == "Ｃontract")
        #expect(LibraryRules.match(for: "CONTRA CT.pdf", in: rules) == nil)
        #expect(LibraryRules.match(for: "合同.pdf", in: [LibraryRule(match: " 合同 ", tags: ["x"])]) != nil)
        #expect(LibraryRules.match(for: "合同.pdf", in: [LibraryRule(match: "   ", tags: ["x"])]) == nil)
    }

    @Test func rulesWithoutAnActionOrMatchAreIgnored() {
        #expect(!LibraryRule(match: "合同").isUseful)
        #expect(!LibraryRule(match: "", collection: "合同").isUseful)
        #expect(LibraryRule(match: "合同", collection: "合同").isUseful)
        #expect(LibraryRule(match: "合同", tags: ["待归档"]).isUseful)
    }

    // MARK: 存储

    @Test func rulesSurviveARoundTripThroughTheLibrary() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rules = [LibraryRule(match: "合同", collection: "合同档案", tags: ["待归档", "法务"]),
                     LibraryRule(match: "发票", tags: ["财务"], isEnabled: false)]
        LibraryRuleStore.save(rules, in: root)

        let loaded = LibraryRuleStore.load(from: root)
        #expect(loaded == rules)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(LibraryRuleStore.fileName).path))
        #expect(LibraryRuleStore.load(from: temporary.appendingPathComponent("Empty")) .isEmpty)
    }

    // MARK: 导入时应用

    @Test func importingAppliesTheCollectionAndTags() async throws {
        let repository = try LibraryRepository(root: root)
        let source = try write("2026合同-终版.md", "# 合同\n\n正文")
        let rules = [LibraryRule(match: "合同", collection: "合同档案", tags: ["待归档", "法务"])]

        let report = try await repository.importFiles(try await repository.previewImport([source]),
                                                      skippingDuplicates: false, rules: rules)
        #expect(report.ruled == ["2026合同-终版.md"])

        let snapshot = try await repository.snapshot()
        let item = try #require(snapshot.items.first)
        let collection = try #require(snapshot.collections.first { $0.name == "合同档案" })
        #expect(item.collectionID == collection.id)
        #expect(Set(item.tags) == ["待归档", "法务"])
        // One activity line per import, not one per column it touched.
        #expect(snapshot.activities.filter { $0.message.contains("按规则") }.count == 1)
    }

    @Test func anExistingCollectionIsReusedWhateverItsCase() async throws {
        let repository = try LibraryRepository(root: root)
        _ = try await repository.createCollection(name: "MRR")
        let source = try write("mrr-十月.md", "数字")
        let rules = [LibraryRule(match: "mrr", collection: "mrr")]

        _ = try await repository.importFiles(try await repository.previewImport([source]),
                                             skippingDuplicates: false, rules: rules)
        let snapshot = try await repository.snapshot()
        #expect(snapshot.collections.filter { $0.name.lowercased() == "mrr" }.count == 1)
        #expect(snapshot.items.first?.collectionID == snapshot.collections.first { $0.name == "MRR" }?.id)
    }

    @Test func filesWithoutARuleStayWhereTheyAre() async throws {
        let repository = try LibraryRepository(root: root)
        let source = try write("随手记.md", "正文")
        let report = try await repository.importFiles(try await repository.previewImport([source]),
                                                      skippingDuplicates: false,
                                                      rules: [LibraryRule(match: "合同", tags: ["法务"])])
        #expect(report.ruled.isEmpty)
        let item = try #require(try await repository.snapshot().items.first)
        #expect(item.collectionID == nil)
        #expect(item.tags.isEmpty)
    }

    @Test func tagsOnlyAndCollectionOnlyRulesBothWork() async throws {
        let repository = try LibraryRepository(root: root)
        let tagged = try write("发票-九月.md", "金额")
        let filed = try write("周报-第 40 周.md", "进展")
        let rules = [LibraryRule(match: "发票", tags: ["财务"]),
                     LibraryRule(match: "周报", collection: "周报")]
        _ = try await repository.importFiles(try await repository.previewImport([tagged, filed]),
                                             skippingDuplicates: false, rules: rules)

        let snapshot = try await repository.snapshot()
        let invoice = try #require(snapshot.items.first { $0.title.hasPrefix("发票") })
        let weekly = try #require(snapshot.items.first { $0.title.hasPrefix("周报") })
        #expect(invoice.tags == ["财务"])
        #expect(invoice.collectionID == nil)
        #expect(weekly.tags.isEmpty)
        #expect(snapshot.collections.contains { $0.id == weekly.collectionID && $0.name == "周报" })
    }
}
