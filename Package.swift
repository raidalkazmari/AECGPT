// swift-tools-version:5.7
// حزمة للاختبارات فقط: تختبر قراءة المحادثات والتنسيق على GitHub بدون Mac.
// التطبيق نفسه يُبنى من project.yml.
import PackageDescription

let package = Package(
    name: "AECGPTCore",
    targets: [
        .target(
            name: "AECGPTCore",
            path: "Shared",
            exclude: ["ChatSnapshot.swift"],
            sources: ["ChatMessage.swift", "ConversationParser.swift", "Markdown.swift"]
        ),
        .testTarget(
            name: "AECGPTCoreTests",
            dependencies: ["AECGPTCore"],
            path: "Tests/AECGPTCoreTests"
        ),
    ]
)
