// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PersonalLibrary",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PersonalLibrary", targets: ["PersonalLibrary"])],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", exact: "2.4.1"),
        .package(url: "https://github.com/swiftlang/swift-cmark", exact: "0.9.0")
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "LibraryCore", dependencies: [
            "CSQLite", .product(name: "cmark-gfm", package: "swift-cmark"),
            .product(name: "cmark-gfm-extensions", package: "swift-cmark")
        ]),
        .executableTarget(name: "PersonalLibrary", dependencies: [
            "LibraryCore", .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            .product(name: "cmark-gfm", package: "swift-cmark"),
            .product(name: "cmark-gfm-extensions", package: "swift-cmark")
        ]),
        .testTarget(name: "LibraryCoreTests", dependencies: ["LibraryCore"]),
        .testTarget(name: "PersonalLibraryTests", dependencies: [
            "PersonalLibrary", "LibraryCore", .product(name: "MarkdownUI", package: "swift-markdown-ui")
        ])
    ]
)
