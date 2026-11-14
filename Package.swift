// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Unableton",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "Unableton", targets: ["Unableton"])],
    targets: [
        .target(name: "UnabletonCore", resources: [.process("Resources")]),
        .target(name: "UnabletonLibrary", dependencies: ["UnabletonCore"]),
        .target(name: "UnabletonDSP", publicHeadersPath: "include", linkerSettings: [.linkedFramework("AVFAudio"), .linkedFramework("AudioToolbox")]),
        .target(name: "UnabletonAudio", dependencies: ["UnabletonCore", "UnabletonDSP"]),
        .target(name: "UnabletonAI", dependencies: ["UnabletonCore"]),
        .executableTarget(name: "Unableton", dependencies: ["UnabletonCore", "UnabletonAudio", "UnabletonAI", "UnabletonLibrary"]),
        .testTarget(name: "UnabletonLibraryTests", dependencies: ["UnabletonLibrary"]),
        .testTarget(name: "UnabletonCoreTests", dependencies: ["UnabletonCore"]),
        .testTarget(name: "UnabletonAudioTests", dependencies: ["UnabletonAudio"]),
        .testTarget(name: "UnabletonAITests", dependencies: ["UnabletonAI"]),
        .testTarget(name: "UnabletonAppTests", dependencies: ["Unableton"])
    ],
    cxxLanguageStandard: .cxx17
)
