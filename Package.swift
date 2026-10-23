// swift-tools-version: 5.10
import PackageDescription
import Foundation
let projectRoot = URL(fileURLWithPath:#filePath).deletingLastPathComponent().path
let rtcFrameworks=projectRoot+"/Vendor/webrtc/WebRTC.xcframework/macos-x86_64_arm64"
let package = Package(
    name: "LiveCaption", platforms: [.macOS("14.2")],
    products: [.executable(name: "LiveCaption", targets: ["LiveCaptionApp"]), .library(name: "LiveCaptionCore", targets: ["LiveCaptionCore"])],
    dependencies: [.package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1")],
    targets: [
        .target(name: "AudioBridge", publicHeadersPath: "include", cxxSettings: [
            .headerSearchPath("../../Vendor/install/include/webrtc-audio-processing-2"),
            .headerSearchPath("../../Vendor/install/include"),
            .define("WEBRTC_MAC"), .define("WEBRTC_POSIX")
        ], linkerSettings: [.linkedFramework("AudioToolbox"), .linkedFramework("CoreAudio"),
            .unsafeFlags(["-L", "Vendor/install/lib", "-llivecaption-apm"]) ]),
        .target(name:"AoqBridge",publicHeadersPath:"include",cSettings:[.unsafeFlags(["-F"+projectRoot+"/Vendor/aoq","-fobjc-arc"])],linkerSettings:[.unsafeFlags(["-F"+projectRoot+"/Vendor/aoq","-framework","AoqClientSdk","-Xlinker","-rpath","-Xlinker","@executable_path/../Frameworks","-Xlinker","-rpath","-Xlinker",projectRoot+"/Vendor/aoq","-Xlinker","-rpath","-Xlinker",projectRoot+"/Vendor/aoq/AoqClientSdk.framework/Versions/A/Frameworks"])]),
        .target(name: "LiveCaptionCore",dependencies:["WebRTCBridge", .product(name:"WhisperKit",package:"WhisperKit")]),
        .target(name:"WebRTCBridge",publicHeadersPath:"include",cxxSettings:[.unsafeFlags(["-F"+rtcFrameworks,"-fobjc-arc"])],linkerSettings:[.unsafeFlags(["-F"+rtcFrameworks,"-framework","WebRTC","-Xlinker","-rpath","-Xlinker","@executable_path/../Frameworks","-Xlinker","-rpath","-Xlinker",rtcFrameworks])]),
        .target(name:"LiveCaptionTransportExperiments",dependencies:["LiveCaptionCore","AoqBridge"],path:"Experiments/RealtimeTransports",exclude:["README.md"]),
        .executableTarget(name: "LiveCaptionApp", dependencies: ["LiveCaptionCore", "AudioBridge"]),
        .executableTarget(name: "LiveCaptionChecks", dependencies: ["LiveCaptionCore", "AudioBridge"], path: "Tests/LiveCaptionCoreTests"),
        .executableTarget(name:"LiveCaptionModelSetup",dependencies:["LiveCaptionCore"]),
        .executableTarget(name: "LiveCaptionReflowProbe", dependencies: ["LiveCaptionCore"], path: "Sources/LiveCaptionReflowProbe"),
        .executableTarget(name: "LiveCaptionWhisperProbe", dependencies: ["LiveCaptionCore"], path:"Sources/LiveCaptionWhisperProbe"),
        .executableTarget(name: "LiveCaptionVerify", dependencies: ["LiveCaptionCore","LiveCaptionTransportExperiments"], path: "Sources/LiveCaptionVerify")
    ], cxxLanguageStandard: .cxx17
)
