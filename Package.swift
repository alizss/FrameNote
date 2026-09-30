// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FrameNote",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "FrameNote", targets: ["FrameNote"])],
    targets: [
        .target(name: "FrameNoteCore"),
        .executableTarget(name: "FrameNote", dependencies: ["FrameNoteCore"]),
        .testTarget(name: "FrameNoteTests", dependencies: ["FrameNoteCore", "FrameNote"]),
    ]
)
