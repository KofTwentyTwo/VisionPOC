import SwiftUI

struct AboutView: View {
    private let appVersion: String = {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "v\(short) (build \(build))"
    }()

    private let cyan = Color(red: 0.20, green: 0.95, blue: 1.00)
    private let mint = Color(red: 0.30, green: 1.00, blue: 0.80)
    private let amber = Color(red: 1.00, green: 0.75, blue: 0.20)
    private let magenta = Color(red: 1.00, green: 0.45, blue: 0.85)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                Divider().background(Color(white: 0.18))

                section(title: "WHAT IT IS", accent: cyan) {
                    line("Real-time camera vision proof-of-concept for macOS. Captures live video and processes every frame through Apple Silicon's GPU and Neural Engine to produce four synchronized views: live, Jarvis stylization, edge map, and ASCII art — with object detection, face recognition, gesture / activity / expression recognition, and OCR overlaid on top.")
                    line("Sibling to MetalPOC (Jarvis HUD spine) and VoicePOC (voice stack) under the Kingsrook Jarvis program.")
                }

                section(title: "DETECTION", accent: mint) {
                    bullet("YOLOv8x trained on Open Images V7 — 601 object classes",
                           detail: "Ultralytics · github.com/ultralytics/ultralytics")
                    bullet("Apple Vision framework",
                           detail: "VNRecognizeText, VNDetectFaceLandmarks, VNDetectHumanBody/HandPose, VNRecognizeAnimals, VNTrackObject, VNGenerateImageFeaturePrint")
                    bullet("Core ML + Apple Neural Engine",
                           detail: "MLComputeUnits.all — Apple's runtime picks the ANE wherever possible")
                }

                section(title: "RENDERING", accent: amber) {
                    bullet("Metal 4 + MetalKit",
                           detail: "Single render pass, four viewports, custom fragment shaders for stylization / edges / ASCII / lines")
                    bullet("MetalPerformanceShaders MPSImageSobel",
                           detail: "GPU-native edge detection at sub-millisecond cost")
                    bullet("AVFoundation + CVMetalTextureCache",
                           detail: "Zero-copy capture → MTLTexture pipeline")
                }

                section(title: "TYPOGRAPHY", accent: magenta) {
                    bullet("Share Tech Mono",
                           detail: "Carrois Apostrophe · SIL Open Font License")
                    bullet("Orbitron",
                           detail: "Matt McInerney · SIL Open Font License")
                }

                section(title: "INSPIRATION", accent: cyan) {
                    line("Jarvis / Iron Man cinematic HUD aesthetic — cyan tints, scanlines, hex grids, corner brackets, scanning beams.")
                }

                section(title: "LICENSE", accent: Color(white: 0.65)) {
                    line("MIT License · Copyright © 2026 James Maes")
                    link("github.com/KofTwentyTwo/VisionPOC",
                         url: URL(string: "https://github.com/KofTwentyTwo/VisionPOC")!)
                }

                section(title: "BUILT WITH", accent: Color(white: 0.65)) {
                    line("Claude Opus + Claude Code — Anthropic")
                    line("XcodeGen · git-lfs · Swift 6 toolchain")
                }

                Spacer(minLength: 8)
            }
            .padding(20)
        }
        .frame(minWidth: 460, idealWidth: 540, minHeight: 480, idealHeight: 620)
        .background(Color(white: 0.06))
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("VISIONPOC")
                .font(.system(size: 28, weight: .heavy, design: .monospaced))
                .tracking(4)
                .foregroundStyle(cyan)
            HStack(spacing: 12) {
                Text(appVersion)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.secondary)
                Text("Kingsrook Jarvis Program")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func section<Content: View>(title: String, accent: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(accent)
            content()
        }
    }

    @ViewBuilder
    private func line(_ text: String) -> some View {
        Text(text)
            .font(.system(.callout))
            .foregroundStyle(.primary.opacity(0.92))
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func bullet(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("›")
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(.callout, weight: .medium))
                    .foregroundStyle(.primary)
            }
            Text(detail)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.leading, 16)
        }
    }

    @ViewBuilder
    private func link(_ text: String, url: URL) -> some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color(red: 0.20, green: 0.95, blue: 1.00))
        }
        .buttonStyle(.plain)
    }
}
