import SwiftUI

struct Theme {
    let redMode: Bool
    var accent: Color { redMode ? Color(red: 0.85, green: 0, blue: 0) : .yellow }
    var primary: Color { redMode ? Color(red: 0.7, green: 0, blue: 0) : .white }
    var secondary: Color { redMode ? Color(red: 0.4, green: 0, blue: 0) : .gray }
}

struct ContentView: View {
    @StateObject private var camera = CameraController()
    @StateObject private var intervalometer = Intervalometer()
    @StateObject private var level = LevelMonitor()
    @AppStorage("redMode") private var redMode = false
    @AppStorage("showGrid") private var showGrid = false
    @AppStorage("showLevel") private var showLevel = true
    @AppStorage("showHistogram") private var showHistogram = true
    @AppStorage("peaking") private var peaking = false
    @State private var selectedSetting: CameraSetting = .shutter
    @State private var showIntervalometer = false
    @State private var showSettings = false
    @State private var tapPoint: CGPoint?

    private var theme: Theme { Theme(redMode: redMode) }

    private var keepAwake: Bool {
        intervalometer.isRunning || camera.isStacking || camera.lightningArmed || camera.timerRemaining != nil
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if camera.permissionDenied {
                Text("Camera access is off.\nTurn it on in Settings → Privacy & Security → Camera.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(theme.primary)
                    .padding()
            } else {
                VStack(spacing: 10) {
                    topBar
                    preview
                    MeterRow(camera: camera, theme: theme)
                    SettingsPanel(camera: camera, selected: $selectedSetting, theme: theme)
                    lensPicker
                    bottomBar
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
        .tint(theme.accent)
        .onAppear {
            camera.start()
            level.start()
            camera.setPeaking(peaking, redMode: redMode)
        }
        .onChange(of: peaking) { _, on in camera.setPeaking(on, redMode: redMode) }
        .onChange(of: redMode) { _, red in camera.setPeaking(peaking, redMode: red) }
        .onChange(of: keepAwake) { _, awake in UIApplication.shared.isIdleTimerDisabled = awake }
        .sheet(isPresented: $showIntervalometer) {
            IntervalometerView(intervalometer: intervalometer, camera: camera, theme: theme)
                .presentationDetents([.medium])
                .presentationBackground(.black)
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(camera: camera, theme: theme, showGrid: $showGrid, showLevel: $showLevel,
                          showHistogram: $showHistogram, peaking: $peaking)
                .presentationBackground(.black)
        }
    }

    /// Shutter button, volume buttons and Camera Control.
    private func shutter() {
        if intervalometer.isRunning {
            intervalometer.stop()
            if camera.isStacking { camera.finishStack() }
            return
        }
        camera.shutterPressed()
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 14) {
            chip(camera.format.rawValue) {
                let options = OutputFormat.allCases.filter { camera.rawSupported || !$0.needsRAW }
                if let i = options.firstIndex(of: camera.format) {
                    camera.format = options[(i + 1) % options.count]
                }
            }
            chip(camera.stackMode.shortName) {
                let modes = StackMode.allCases
                if let i = modes.firstIndex(of: camera.stackMode) {
                    camera.stackMode = modes[(i + 1) % modes.count]
                    camera.show("Stacking: \(camera.stackMode.rawValue)")
                }
            }
            Spacer()
            iconButton(camera.lightningArmed ? "bolt.fill" : "bolt", active: camera.lightningArmed) {
                camera.setLightning(!camera.lightningArmed)
            }
            .disabled(camera.isStacking)
            iconButton("scope", active: peaking) { peaking.toggle() }
            iconButton("plus.magnifyingglass", active: camera.magnifierOn) {
                camera.setMagnifier(!camera.magnifierOn)
            }
            iconButton(redMode ? "eye.fill" : "eye", active: redMode) { redMode.toggle() }
            iconButton("gearshape", active: false) { showSettings = true }
        }
        .foregroundStyle(theme.primary)
    }

    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(.caption, design: .monospaced).bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .overlay(Capsule().stroke(theme.primary, lineWidth: 1))
        }
    }

    private func iconButton(_ symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .frame(width: 28, height: 32)
        }
        .foregroundStyle(active ? theme.accent : theme.primary)
    }

    // MARK: - Preview

    private var preview: some View {
        ZStack {
            CameraPreview(camera: camera, redMode: redMode, onShutterEvent: shutter)
                .onTapGesture { location in
                    tapPoint = location
                    camera.focus(atLayerPoint: location)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        if tapPoint == location { tapPoint = nil }
                    }
                }

            Group {
                if peaking, let image = camera.peakingImage {
                    Image(decorative: image, scale: 1)
                        .resizable()
                }
                if showGrid {
                    GridOverlay(color: theme.primary.opacity(0.35))
                }
                if showLevel {
                    LevelOverlay(level: level, theme: theme)
                }
                if let point = tapPoint {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(theme.accent, lineWidth: 1.5)
                        .frame(width: 70, height: 70)
                        .position(point)
                }
            }
            .allowsHitTesting(false)
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .overlay(alignment: .topLeading) {
            if showHistogram && !camera.histogram.isEmpty {
                HistogramView(bins: camera.histogram, color: theme.primary)
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) {
            if let status = statusText {
                badge(status).padding(.top, showHistogram ? 58 : 0)
            }
        }
        .overlay(alignment: .bottom) {
            if let message = camera.lastMessage {
                badge(message)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusText: String? {
        if let remaining = camera.timerRemaining {
            return "Self-timer \(remaining)"
        }
        if camera.isStacking {
            let elapsed = Double(camera.stackFrames) * camera.stackSubExposure
            if let target = camera.stackFrameTarget {
                if camera.stackFrames >= target { return "Processing…" }
                let total = Double(target) * camera.stackSubExposure
                return String(format: "Exposing %.0f / %.0fs", elapsed, total)
            }
            return String(format: "BULB %.0fs · press shutter to end", elapsed)
        }
        if intervalometer.isRunning {
            return intervalometer.statusText
        }
        if camera.lightningArmed {
            return "Watching for lightning · \(camera.lightningCount) caught"
        }
        return nil
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.footnote.monospacedDigit())
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.65), in: Capsule())
            .foregroundStyle(theme.primary)
            .padding(8)
            .allowsHitTesting(false)
    }

    // MARK: - Bottom

    private var lensPicker: some View {
        HStack(spacing: 12) {
            ForEach(camera.lenses) { lens in
                Button {
                    camera.selectLens(lens.id)
                } label: {
                    Text(lens.name)
                        .font(.footnote.bold())
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                }
                .foregroundStyle(lens.id == camera.currentLensID ? theme.accent : theme.primary)
            }
        }
    }

    private var bottomBar: some View {
        HStack {
            Button {
                showIntervalometer = true
            } label: {
                Image(systemName: "timelapse")
                    .font(.title2)
                    .frame(width: 56, height: 56)
            }
            .foregroundStyle(intervalometer.isRunning ? theme.accent : theme.primary)

            Spacer()
            shutterButton
            Spacer()

            Button {
                let options = [0, 2, 10]
                let i = options.firstIndex(of: camera.selfTimerSeconds) ?? 0
                camera.selfTimerSeconds = options[(i + 1) % options.count]
                camera.show(camera.selfTimerSeconds == 0 ? "Self-timer off" : "Self-timer \(camera.selfTimerSeconds)s")
            } label: {
                VStack(spacing: 0) {
                    Image(systemName: "timer").font(.title2)
                    if camera.selfTimerSeconds > 0 {
                        Text("\(camera.selfTimerSeconds)s").font(.caption2.bold())
                    }
                }
                .frame(width: 56, height: 56)
            }
            .foregroundStyle(camera.selfTimerSeconds > 0 ? theme.accent : theme.primary)
        }
    }

    private var stackProgress: Double {
        guard camera.isStacking, let target = camera.stackFrameTarget, target > 0 else { return 0 }
        return min(1, Double(camera.stackFrames) / Double(target))
    }

    private var shutterButton: some View {
        Button(action: shutter) {
            ZStack {
                Circle()
                    .stroke(theme.primary.opacity(camera.isStacking ? 0.3 : 1), lineWidth: 4)
                    .frame(width: 74, height: 74)
                if camera.isStacking {
                    Circle()
                        .trim(from: 0, to: camera.stackFrameTarget == nil ? 1 : stackProgress)
                        .stroke(theme.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 74, height: 74)
                }
                if camera.isStacking || intervalometer.isRunning {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(theme.accent)
                        .frame(width: 28, height: 28)
                } else if let remaining = camera.timerRemaining {
                    Text("\(remaining)")
                        .font(.title.bold().monospacedDigit())
                        .foregroundStyle(theme.accent)
                } else {
                    Circle()
                        .fill(camera.isCapturing ? theme.secondary : (camera.isLongExposure ? theme.accent : theme.primary))
                        .frame(width: 60, height: 60)
                }
            }
        }
        .disabled(camera.isCapturing && !intervalometer.isRunning)
    }
}
