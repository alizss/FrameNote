import SwiftUI

enum FrameNoteTheme: String, CaseIterable, Identifiable {
    case light, dark, system
    var id: String { rawValue }
    var title: String { switch self { case .system: "System"; case .light: "Light"; case .dark: "Dark" } }
    var scheme: ColorScheme? { switch self { case .light: .light; case .dark: .dark; case .system: nil } }
}

enum SurfaceStyle: String, CaseIterable, Identifiable {
    case solid, glass
    var id: String { rawValue }
    var title: String { self == .solid ? "Solid" : "Glass" }
}

enum WorkspaceDensity: String, CaseIterable, Identifiable {
    case compact, comfortable
    var id: String { rawValue }
    var title: String { self == .compact ? "Compact" : "Comfortable" }
    var spacing: CGFloat { self == .compact ? 8 : 12 }
    var padding: CGFloat { self == .compact ? 12 : 18 }
}

struct FrameNoteSurface: ViewModifier {
    let theme: FrameNoteTheme
    let compact: Bool
    @AppStorage("appearance.surface") private var surface: SurfaceStyle = .solid
    @AppStorage("appearance.glassTint") private var tint = 0.15
    @AppStorage("appearance.cornerRadius") private var radius = 12.0
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: compact ? 6 : 0)
        if surface == .glass && compact && !reduceTransparency {
            if #available(macOS 26.0, *) {
                content.glassEffect(.regular.tint(Color(nsColor: .windowBackgroundColor).opacity(tint)), in: shape)
            } else { content.background(.regularMaterial, in: shape) }
        } else {
            content.background(Color(nsColor: .windowBackgroundColor), in: shape)
                .overlay(shape.stroke(.primary.opacity(0.08), lineWidth: 1))
        }
    }
}

struct FrameNoteChrome: ViewModifier {
    @AppStorage("appearance.surface") private var surface: SurfaceStyle = .solid
    @AppStorage("appearance.glassToolbar") private var enabled = false
    @AppStorage("appearance.glassTint") private var tint = 0.15
    @AppStorage("appearance.cornerRadius") private var radius = 12.0
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        if enabled && surface == .glass && !reduceTransparency {
            if #available(macOS 26.0, *) {
                content.glassEffect(.regular.tint(Color(nsColor: .windowBackgroundColor).opacity(tint)), in: RoundedRectangle(cornerRadius: radius))
            } else { content.background(.thinMaterial, in: RoundedRectangle(cornerRadius: radius)) }
        } else { content }
    }
}

enum SettingsSection: String { case appearance, workspace, ai }

struct FrameNoteSettingsView: View {
    @AppStorage("appearance.theme") private var theme: FrameNoteTheme = .light
    @AppStorage("appearance.surface") private var surface: SurfaceStyle = .solid
    @AppStorage("appearance.glassTint") private var tint = 0.15
    @AppStorage("appearance.glassToolbar") private var glassToolbar = false
    @AppStorage("appearance.cornerRadius") private var radius = 12.0
    @AppStorage("layout.density") private var density: WorkspaceDensity = .compact
    @AppStorage("layout.advancedTools") private var advancedTools = false
    @AppStorage("reviewCommentsOpen") private var comments = true
    @AppStorage("layout.hideEmptyComments") private var hideEmptyComments = true
    @AppStorage("reviewDetailsOpen") private var sharing = false
    @AppStorage("layout.showHints") private var hints = false
    @AppStorage("layout.sidebarWidth") private var sidebarWidth = 268.0
    @AppStorage("layout.resetGeneration") private var layoutResetGeneration = 0
    @State private var section: SettingsSection
    var onSavedAI: () -> Void
    var onClose: () -> Void

    init(section: SettingsSection, onSavedAI: @escaping () -> Void, onClose: @escaping () -> Void) {
        _section = State(initialValue: section)
        self.onSavedAI = onSavedAI; self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Settings", selection: $section) {
                Text("Appearance").tag(SettingsSection.appearance)
                Text("Workspace").tag(SettingsSection.workspace)
                Text("AI connections").tag(SettingsSection.ai)
            }.pickerStyle(.segmented).padding(20)
            if section == .ai {
                ScrollView { AISettingsView(onSave: onSavedAI, onCancel: onClose) }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(section == .appearance ? "Appearance" : "Workspace").font(.title2.weight(.semibold))
                        Text("Changes apply immediately. Use the preview below, or close Settings to try the workspace.")
                            .font(.callout).foregroundStyle(.secondary)
                        preview
                        if section == .appearance { appearanceControls }
                        else { workspaceControls }
                    }.padding(.horizontal, 22).padding(.bottom, 18)
                }
                HStack {
                    Button("Reset to clean defaults") { reset() }
                    Spacer()
                    Button("Done", action: onClose).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }.padding(20)
            }
        }
        .frame(width: 564, height: 620)
        .preferredColorScheme(theme.scheme)
    }

    private var appearanceControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            labeled("Color mode") {
                Picker("Color mode", selection: $theme) { ForEach(FrameNoteTheme.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
            }
            labeled("Surface") {
                Picker("Surface", selection: $surface) { ForEach(SurfaceStyle.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
            }
            if surface == .glass {
                Toggle("Glass in the review header", isOn: $glassToolbar)
                labeled("Glass tint · \(Int(tint * 100))%") { Slider(value: $tint, in: 0...0.8, step: 0.05) }
                Text("Glass is independent of color mode. Use Light + Glass for a light translucent style.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            labeled("Corner radius · \(Int(radius))") { Slider(value: $radius, in: 6...24, step: 1) }
        }
    }

    private var workspaceControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            labeled("Spacing") {
                Picker("Spacing", selection: $density) { ForEach(WorkspaceDensity.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
            }
            Toggle("Show advanced tools in the toolbar", isOn: $advancedTools)
            Toggle("Show comments sidebar", isOn: $comments)
            Toggle("Hide the sidebar when there are no comments", isOn: $hideEmptyComments)
            Toggle("Expand files & feedback", isOn: $sharing)
            Toggle("Show gesture hints", isOn: $hints)
            labeled("Comments width · \(Int(sidebarWidth)) pt") { Slider(value: $sidebarWidth, in: 220...420, step: 10) }
            Text("Comment, Box, Arrow, Analyze, Undo, and Copy stay accessible. Extra measurement tools are available in More tools.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: density.spacing) {
            HStack {
                Image(systemName: "viewfinder").foregroundStyle(Color.accentColor)
                Text("FrameNote").fontWeight(.semibold)
                Spacer()
                Image(systemName: "gearshape").foregroundStyle(.secondary)
            }.frame(height: 24).modifier(FrameNoteChrome())
            HStack(spacing: 12) {
                Text("Comment").foregroundStyle(Color.accentColor)
                Text("Box"); Text("Arrow")
                if advancedTools { Text("Measure") }
                Spacer()
                Text("Analyze").foregroundStyle(Color.accentColor)
            }
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: radius).fill(Color.primary.opacity(0.05))
                    .overlay { Text("Your reference").foregroundStyle(.secondary) }
                if comments {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Comments").fontWeight(.semibold)
                        Text("Keep focus here.").foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }.frame(width: 110, alignment: .leading).padding(8)
                }
            }.frame(height: 65)
            if sharing { Text("Files & feedback").foregroundStyle(.secondary) }
        }
        .font(.system(size: 11)).padding(density.padding)
        .modifier(FrameNoteSurface(theme: theme, compact: true))
        .overlay(alignment: .topTrailing) { Text("Preview").font(.system(size: 9)).foregroundStyle(.secondary).padding(4).offset(y: -16) }
        .padding(.top, 8)
    }

    private func labeled<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) { Text(label).font(.callout.weight(.medium)); content() }
    }

    private func reset() {
        theme = .light; surface = .solid; tint = 0.15; glassToolbar = false; radius = 12
        density = .compact; advancedTools = false; comments = true; hideEmptyComments = true
        sharing = false; hints = false; sidebarWidth = 268
        layoutResetGeneration += 1
    }
}

struct LauncherActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .padding(.horizontal, 12)
            .background(Color.primary.opacity(configuration.isPressed ? 0.1 : 0.045), in: RoundedRectangle(cornerRadius: 11))
            .contentShape(RoundedRectangle(cornerRadius: 11))
    }
}
