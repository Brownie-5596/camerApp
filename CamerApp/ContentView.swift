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
    @State private var showPresets = false
    @State private var tapPoint: CGPoint?
    @State private var pinchStartZoom: CGFloat?
    @State private var burstTask: Task<Void, Never>?
    @State private var burstCount = 0
    @State private var lastCrash: String? = Diagnostics.takeLastCrash()
    /// How far the screen is turned from portrait, in degrees clockwise (for the level).
    @State private var interfaceRotation: Double = 0

    private var theme: Theme { Theme(redMode: redMode) }

    private var keepAwake: Bool {
        intervalometer.isRunning || camera.isStacking || camera.lightningArmed || camera.timerRemaining != nil
            || burstTask != nil
    }

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            ZStack {
                Color.black.ignoresSafeArea()
                if camera.permissionDenied {
                    Text("Camera access is off.\nTurn it on in Settings → Privacy & Security → Camera.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(theme.primary)
                        .padding()
                } else if landscape {
                    landscapeLayout
                } else {
                    portraitLayout
                }
            }
            .onChange(of: landscape) { _, _ in updateInterfaceRotation() }
        }
        .tint(theme.accent)
        .onAppear {
            updateInterfaceRotation()
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
        .alert("CamerApp crashed last time", isPresented: Binding(get: { lastCrash != nil },
                                                                  set: { if !$0 { lastCrash = nil } })) {
            Button("Copy details") { UIPasteboard.general.string = lastCrash }
            Button("OK", role: .cancel) {}
        } message: {
            Text((lastCrash ?? "") + "\n\nTap Copy details and paste it to Claude.")
        }
        .sheet(isPresented: $showPresets) {
            PresetsSheet(camera: camera, theme: theme)
                .presentationBackground(.black)
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(camera: camera, theme: theme, showGrid: $showGrid, showLevel: $showLevel,
                          showHistogram: $showHistogram, peaking: $peaking)
                .presentationBackground(.black)
        }
    }

    private var portraitLayout: some View {
        VStack(spacing: 8) {
            topBar
            statusLine
            preview(aspectRatio: 3.0 / 4.0)
            MeterRow(camera: camera, theme: theme)
            SettingsPanel(camera: camera, selected: $selectedSetting, theme: theme)
            HStack(spacing: 12) {
                modesButton
                Spacer()
                ForEach(camera.lenses) { lensButton($0) }
                Spacer()
                Color.clear.frame(width: 56, height: 32)
            }
            HStack {
                intervalometerButton
                Spacer()
                shutterButton
                Spacer()
                selfTimerButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    /// Landscape: lenses on the left, preview in the middle, dials and shutter on the right.
    private var landscapeLayout: some View {
        HStack(spacing: 10) {
            VStack(spacing: 10) {
                modesButton
                ForEach(camera.lenses) { lensButton($0) }
                Spacer(minLength: 0)
                intervalometerButton
                selfTimerButton
            }
            .frame(width: 60)

            VStack(spacing: 6) {
                topBar
                statusLine
                preview(aspectRatio: 4.0 / 3.0)
            }

            VStack(spacing: 8) {
                MeterRow(camera: camera, theme: theme)
                SettingsPanel(camera: camera, selected: $selectedSetting, theme: theme)
                Spacer(minLength: 0)
                shutterButton
                Spacer(minLength: 0)
            }
            .frame(width: 250)
        }
        .padding(.vertical, 6)
    }

    private func updateInterfaceRotation() {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        switch scene?.interfaceOrientation {
        case .landscapeLeft: interfaceRotation = 90
        case .landscapeRight: interfaceRotation = -90
        case .portraitUpsideDown: interfaceRotation = 180
        default: interfaceRotation = 0
        }
    }

    /// Hold the shutter button to shoot continuously until you let go.
    private func startBurst() {
        guard burstTask == nil, !intervalometer.isRunning, !camera.isStacking, camera.timerRemaining == nil else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        burstCount = 0
        burstTask = Task { @MainActor in
            while !Task.isCancelled {
                let ok = await camera.takePictureAsync()
                if !ok { break }
                burstCount += 1
            }
        }
    }

    private func stopBurst() {
        guard let task = burstTask else { return }
        task.cancel()
        burstTask = nil
        // Releasing during a stacked exposure ends it and keeps what was collected.
        if camera.isStacking { camera.finishStack() }
        if burstCount > 0 { camera.show("Burst: \(burstCount) shots") }
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
        HStack(spacing: 6) {
            chip(camera.format.rawValue) {
                let options = OutputFormat.allCases.filter { format in
                    switch format {
                    case .heif: return true
                    case .proRAW: return camera.proRAWSupported
                    case .raw, .rawPlusHEIF: return camera.rawSupported
                    }
                }
                if let i = options.firstIndex(of: camera.format) {
                    camera.format = options[(i + 1) % options.count]
                }
            }
            if camera.availableMegapixels.count > 1 {
                chip("\(camera.effectiveMegapixels)MP") {
                    let choices = camera.availableMegapixels
                    let i = choices.firstIndex(of: camera.effectiveMegapixels) ?? 0
                    camera.preferredMegapixels = choices[(i + 1) % choices.count]
                    camera.show("Photo size \(camera.effectiveMegapixels) MP")
                }
            }
            chip(camera.stackMode.shortName) {
                let modes = StackMode.allCases
                if let i = modes.firstIndex(of: camera.stackMode) {
                    camera.stackMode = modes[(i + 1) % modes.count]
                    camera.show("Long exposures: \(camera.stackMode.rawValue)")
                }
            }
            Spacer(minLength: 4)
            HStack(spacing: 2) {
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
        }
        .lineLimit(1)
        .foregroundStyle(theme.primary)
    }

    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(.caption2, design: .monospaced).bold())
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .overlay(Capsule().stroke(theme.primary, lineWidth: 1))
        }
    }

    private func iconButton(_ symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .frame(width: 30, height: 30)
        }
        .foregroundStyle(active ? theme.accent : theme.primary)
    }

    /// One line under the top bar for everything the camera is telling you.
    private var statusLine: some View {
        let parts = [statusText, camera.lastMessage].compactMap { $0 }
        return Text(parts.isEmpty ? " " : parts.joined(separator: "  ·  "))
            .font(.caption.monospacedDigit())
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(camera.lastMessage != nil ? theme.accent : theme.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 16)
    }

    // MARK: - Preview

    private func preview(aspectRatio: CGFloat) -> some View {
        ZStack {
            CameraPreview(camera: camera, redMode: redMode, onShutterEvent: shutter)
                .onTapGesture { location in
                    tapPoint = location
                    camera.focus(atLayerPoint: location)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        if tapPoint == location { tapPoint = nil }
                    }
                }
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in
                            let start = pinchStartZoom ?? camera.zoomFactor
                            pinchStartZoom = start
                            camera.setZoom(start * value.magnification)
                        }
                        .onEnded { _ in pinchStartZoom = nil }
                )

            Group {
                if peaking, let image = camera.peakingImage {
                    Image(decorative: image, scale: 1)
                        .resizable()
                }
                if showGrid {
                    GridOverlay(color: theme.primary.opacity(0.35))
                }
                if showLevel {
                    LevelOverlay(level: level, theme: theme, interfaceRotation: interfaceRotation)
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
        .aspectRatio(aspectRatio, contentMode: .fit)
        .overlay(alignment: .topLeading) {
            if showHistogram && !camera.histogram.isEmpty {
                HistogramView(bins: camera.histogram, color: theme.primary)
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            if camera.zoomFactor > 1.01 {
                Button {
                    camera.setZoom(1)
                } label: {
                    Text(String(format: "%.1f×", camera.zoomFactor))
                        .font(.caption.bold().monospacedDigit())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.6), in: Capsule())
                }
                .foregroundStyle(theme.accent)
                .padding(8)
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
        if burstTask != nil {
            return "Burst · \(burstCount) shots"
        }
        if intervalometer.isRunning {
            return intervalometer.statusText
        }
        if camera.lightningArmed {
            return "Watching for lightning · \(camera.lightningCount) caught"
        }
        return nil
    }

    // MARK: - Bottom

    private var modesButton: some View {
        Button {
            showPresets = true
        } label: {
            Text("MODES")
                .font(.system(.caption2, design: .monospaced).bold())
                .fixedSize()
                .frame(width: 56, height: 32)
                .overlay(Capsule().stroke(theme.primary, lineWidth: 1))
        }
        .foregroundStyle(theme.primary)
    }

    private func lensButton(_ lens: LensOption) -> some View {
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

    private var intervalometerButton: some View {
        Button {
            showIntervalometer = true
        } label: {
            Image(systemName: "timelapse")
                .font(.title2)
                .frame(width: 56, height: 56)
        }
        .foregroundStyle(intervalometer.isRunning ? theme.accent : theme.primary)
    }

    private var selfTimerButton: some View {
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

    private var stackProgress: Double {
        guard camera.isStacking, let target = camera.stackFrameTarget, target > 0 else { return 0 }
        return min(1, Double(camera.stackFrames) / Double(target))
    }

    private var shutterButton: some View {
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
                    .fill(camera.isCapturing || burstTask != nil
                          ? theme.secondary
                          : (camera.isLongExposure ? theme.accent : theme.primary))
                    .frame(width: 60, height: 60)
            }
        }
        .contentShape(Circle())
        .onTapGesture(perform: shutter)
        .onLongPressGesture(minimumDuration: 0.4, perform: startBurst) { pressing in
            if !pressing { stopBurst() }
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Shutter")
    }
}
