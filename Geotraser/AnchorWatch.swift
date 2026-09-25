//
//  AnchorWatch.swift
//  GeotraserTestV.0
//
//  Anchor drift alarm ("alarma de fondeo").
//  The sailor fixes the anchor position, enters a swing radius in meters,
//  and the app sounds an alarm if the boat stays outside that circle.
//

import SwiftUI
import CoreLocation
import UserNotifications
import AVFoundation
import AudioToolbox
import Combine

// MARK: - Logic

@MainActor
final class AnchorWatch: ObservableObject {
    enum State: Equatable { case inactive, armed, alarming }

    @Published private(set) var state: State = .inactive
    @Published private(set) var anchorLocation: CLLocation?
    @Published private(set) var radiusMeters: Double = 30
    @Published private(set) var currentDistance: Double?
    @Published private(set) var maxDistance: Double = 0
    @Published private(set) var trail: [CLLocationCoordinate2D] = []
    @Published private(set) var lastAccuracy: Double?

    // Tuning — protects against false alarms from GPS jitter.
    let maxAcceptableAccuracy: Double = 20          // m: fixes worse than this are ignored
    private let requiredConsecutiveOutside = 3      // fixes in a row outside the circle…
    private let requiredSecondsOutside: TimeInterval = 10 // …and for at least this long
    private let snoozeInterval: TimeInterval = 120  // after "Silenciar", re-alarm if still outside
    private let maxTrailPoints = 500

    private var consecutiveOutside = 0
    private var firstOutsideAt: Date?
    private var snoozedUntil: Date?
    private let siren = AlarmSiren()
    private var locationSubscription: AnyCancellable?

    var isActive: Bool { state != .inactive }

    /// Subscribes directly to the location stream, independent of SwiftUI
    /// view updates, so the alarm keeps working with the app in background.
    func attach(to locationManager: LocationManager) {
        guard locationSubscription == nil else { return }
        locationSubscription = locationManager.$lastLocation
            .compactMap { $0 }
            .sink { [weak self] location in
                Task { @MainActor in self?.process(location) }
            }
    }

    func arm(at location: CLLocation, radius: Double) {
        anchorLocation = location
        radiusMeters = radius
        currentDistance = 0
        maxDistance = 0
        trail = [location.coordinate]
        resetOutsideCounters()
        snoozedUntil = nil
        state = .armed
        Self.requestNotificationPermission()
    }

    func disarm() {
        siren.stop()
        state = .inactive
        anchorLocation = nil
        currentDistance = nil
        maxDistance = 0
        trail = []
        resetOutsideCounters()
        snoozedUntil = nil
    }

    /// Stops the siren. If the boat is still outside the circle, the alarm
    /// sounds again after `snoozeInterval`.
    func silence() {
        siren.stop()
        snoozedUntil = Date().addingTimeInterval(snoozeInterval)
        resetOutsideCounters()
        state = .armed
    }

    /// Feed every GPS fix here.
    func process(_ location: CLLocation) {
        guard state != .inactive, let anchor = anchorLocation else { return }

        lastAccuracy = location.horizontalAccuracy
        guard location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= maxAcceptableAccuracy else { return }

        let distance = location.distance(from: anchor)
        currentDistance = distance
        maxDistance = max(maxDistance, distance)
        trail.append(location.coordinate)
        if trail.count > maxTrailPoints {
            trail.removeFirst(trail.count - maxTrailPoints)
        }

        if distance > radiusMeters {
            consecutiveOutside += 1
            if firstOutsideAt == nil { firstOutsideAt = Date() }
        } else {
            resetOutsideCounters()
        }

        guard state == .armed,
              consecutiveOutside >= requiredConsecutiveOutside,
              let since = firstOutsideAt,
              Date().timeIntervalSince(since) >= requiredSecondsOutside else { return }
        if let until = snoozedUntil, Date() < until { return }

        triggerAlarm(distance: distance)
    }

    private func triggerAlarm(distance: Double) {
        state = .alarming
        siren.start()
        Self.sendNotification(distance: distance, radius: radiusMeters)
        print("[ANCHOR] Drift alarm: \(Int(distance)) m (radius \(Int(radiusMeters)) m)")
    }

    private func resetOutsideCounters() {
        consecutiveOutside = 0
        firstOutsideAt = nil
    }

    // Flat-earth approximation: accurate to centimeters at anchoring distances.
    nonisolated static func offsetMeters(from a: CLLocationCoordinate2D,
                                         to b: CLLocationCoordinate2D) -> (east: Double, north: Double) {
        let metersPerDegreeLat = 111_320.0
        let north = (b.latitude - a.latitude) * metersPerDegreeLat
        let east = (b.longitude - a.longitude) * metersPerDegreeLat * cos(a.latitude * .pi / 180)
        return (east, north)
    }

    // MARK: Notifications (reach the sailor when the phone is locked)

    private static func requestNotificationPermission() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private static func sendNotification(distance: Double, radius: Double) {
        let content = UNMutableNotificationContent()
        content.title = "⚓️ Alarma de fondeo"
        content.body = String(format: "¡Tu barco está garreando! Está a %.0f m del ancla (límite %.0f m).",
                              distance, radius)
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        let request = UNNotificationRequest(identifier: "anchor-drift", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - Siren
// Generates a two-tone beep in code (no audio file needed). The .playback
// audio category makes it sound even with the ring/silent switch on silent.

final class AlarmSiren {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var buffer: AVAudioPCMBuffer?
    private var hapticTimer: Timer?
    private var isConfigured = false

    func start() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            if !isConfigured { configure() }
            try engine.start()
            if let buffer {
                player.scheduleBuffer(buffer, at: nil, options: .loops)
            }
            player.play()
        } catch {
            print("[ANCHOR] Siren error: \(error.localizedDescription)")
        }

        hapticTimer?.invalidate()
        hapticTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
    }

    func stop() {
        player.stop()
        engine.stop()
        hapticTimer?.invalidate()
        hapticTimer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func configure() {
        let sampleRate = 44_100.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }

        // 1-second pattern: 0.25 s at 880 Hz, 0.25 s at 1320 Hz, 0.5 s silence.
        let frameCount = AVAudioFrameCount(sampleRate)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let samples = buf.floatChannelData?[0] else { return }
        buf.frameLength = frameCount

        for i in 0..<Int(frameCount) {
            let t = Double(i) / sampleRate
            if t < 0.5 {
                let frequency = t < 0.25 ? 880.0 : 1320.0
                samples[i] = Float(sin(2 * .pi * frequency * t) * 0.8)
            } else {
                samples[i] = 0
            }
        }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        buffer = buf
        isConfigured = true
    }
}

// MARK: - Panel shown in TrackingView

/// Wraps the captured position so it can drive `.sheet(item:)`.
struct PendingAnchor: Identifiable {
    let id = UUID()
    let location: CLLocation
}

struct AnchorWatchPanel: View {
    @ObservedObject var watch: AnchorWatch
    let currentLocation: CLLocation?

    @State private var pendingAnchor: PendingAnchor?
    @State private var showRaiseConfirmation = false

    private let panelBackground = Color(red: 0.05, green: 0.09, blue: 0.14)

    private var currentAccuracy: Double? {
        guard let acc = currentLocation?.horizontalAccuracy, acc >= 0 else { return nil }
        return acc
    }

    private var hasGoodFix: Bool {
        guard let acc = currentAccuracy else { return false }
        return acc <= watch.maxAcceptableAccuracy
    }

    var body: some View {
        VStack(spacing: 16) {
            if watch.isActive {
                activeContent
            } else {
                inactiveContent
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(panelBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.red, lineWidth: watch.state == .alarming ? 3 : 0)
        )
        // sheet(item:) receives the captured position directly, so the sheet can
        // never open before the position is set (which caused a blank sheet).
        .sheet(item: $pendingAnchor) { pending in
            AnchorSetupSheet(anchor: pending.location) { radius in
                watch.arm(at: pending.location, radius: radius)
                pendingAnchor = nil
            } onCancel: {
                pendingAnchor = nil
            }
        }
        .confirmationDialog("¿Levar ancla?",
                            isPresented: $showRaiseConfirmation,
                            titleVisibility: .visible) {
            Button("Levar ancla", role: .destructive) {
                watch.disarm()   // stops siren, clears circle; tracking continues
            }
            Button("Cancelar", role: .cancel) { }
        } message: {
            Text("Se desactivará la alarma de fondeo y seguirás navegando con el seguimiento activo.")
        }
    }

    // Before anchoring: one button that captures the position right away.
    private var inactiveContent: some View {
        VStack(spacing: 12) {
            Button {
                // Fix the position at the moment of the tap; this also opens the sheet.
                if let location = currentLocation {
                    print("[ANCHOR] Fondear tapped — position captured")
                    pendingAnchor = PendingAnchor(location: location)
                } else {
                    print("[ANCHOR] Fondear tapped — no location available")
                }
            } label: {
                Label("Fondear aquí", systemImage: "mappin.and.ellipse")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.cyan)
            .disabled(!hasGoodFix)

            Text(hasGoodFix
                 ? "Tocá al soltar el ancla para fijar su posición."
                 : "Esperando buena señal GPS" + (currentAccuracy.map { String(format: " (±%.0f m)", $0) } ?? "") + "…")
                .font(.caption)
                .foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)
        }
    }

    // While anchored: circle, distances, silence / raise anchor.
    private var activeContent: some View {
        VStack(spacing: 16) {
            if watch.state == .alarming {
                VStack(spacing: 10) {
                    Text("¡TU BARCO ESTÁ GARREANDO!")
                        .font(.title3)
                        .fontWeight(.heavy)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                    Button {
                        watch.silence()
                    } label: {
                        Text("Silenciar alarma")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            }

            if let anchor = watch.anchorLocation {
                AnchorCircleView(anchor: anchor.coordinate,
                                 radius: watch.radiusMeters,
                                 trail: watch.trail,
                                 boat: currentLocation?.coordinate,
                                 isAlarming: watch.state == .alarming)
            }

            HStack(spacing: 0) {
                stat("Distancia", watch.currentDistance.map { String(format: "%.0f m", $0) } ?? "—")
                stat("Radio", String(format: "%.0f m", watch.radiusMeters))
                stat("Máxima", String(format: "%.0f m", watch.maxDistance))
            }

            if let acc = watch.lastAccuracy, acc > watch.maxAcceptableAccuracy || acc < 0 {
                Label("Señal GPS débil — lecturas en pausa", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            Button {
                showRaiseConfirmation = true
            } label: {
                Label("Levar ancla", systemImage: "arrow.up.circle")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.cyan)
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.white.opacity(0.55))
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Circle drawing (north up)

struct AnchorCircleView: View {
    let anchor: CLLocationCoordinate2D
    let radius: Double
    let trail: [CLLocationCoordinate2D]
    let boat: CLLocationCoordinate2D?
    let isAlarming: Bool

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let edge = size / 2 - 10
            let scale = edge / (radius * 1.35)        // leave room outside the circle
            let circleDiameter = radius * scale * 2
            let accent: Color = isAlarming ? .red : .cyan

            ZStack {
                Circle()
                    .fill(accent.opacity(0.12))
                    .frame(width: circleDiameter, height: circleDiameter)
                    .position(center)
                Circle()
                    .stroke(accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .frame(width: circleDiameter, height: circleDiameter)
                    .position(center)

                // Swing trail
                Path { path in
                    for (index, coordinate) in trail.enumerated() {
                        let pt = point(for: coordinate, center: center, scale: scale, edge: edge)
                        if index == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                    }
                }
                .stroke(Color.white.opacity(0.35), lineWidth: 1.5)

                Text("N")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundColor(.white.opacity(0.5))
                    .position(x: center.x, y: center.y - edge - 2)

                Text("⚓️")
                    .font(.title2)
                    .position(center)

                if let boat {
                    Circle()
                        .fill(isAlarming ? Color.red : Color.white)
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(Color.black.opacity(0.4), lineWidth: 1))
                        .position(point(for: boat, center: center, scale: scale, edge: edge))
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 280)
    }

    // Converts a coordinate to a point in the view; clamps to the edge if far away.
    private func point(for coordinate: CLLocationCoordinate2D,
                       center: CGPoint, scale: Double, edge: Double) -> CGPoint {
        let offset = AnchorWatch.offsetMeters(from: anchor, to: coordinate)
        var dx = offset.east * scale
        var dy = -offset.north * scale
        let length = hypot(dx, dy)
        if length > edge {
            dx *= edge / length
            dy *= edge / length
        }
        return CGPoint(x: center.x + dx, y: center.y + dy)
    }
}

// MARK: - Radius entry
// Plain layout (no NavigationStack / Form inside the sheet) — simpler and
// avoids nested-navigation rendering issues when presented from TrackingView.

struct AnchorSetupSheet: View {
    let anchor: CLLocation
    let onConfirm: (Double) -> Void
    let onCancel: () -> Void

    @State private var radiusText = "30"
    @FocusState private var isFocused: Bool

    private let presets: [Int] = [20, 30, 50, 75]

    private var radius: Double? {
        Double(radiusText.replacingOccurrences(of: ",", with: "."))
    }

    private var isValid: Bool {
        guard let r = radius else { return false }
        return (5...500).contains(r)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header with actions
            HStack {
                Button("Cancelar", action: onCancel)
                Spacer()
                Text("Fondear")
                    .font(.headline)
                Spacer()
                Button("Activar") {
                    if let r = radius { onConfirm(r) }
                }
                .fontWeight(.semibold)
                .disabled(!isValid)
            }

            // Captured anchor position
            VStack(alignment: .leading, spacing: 4) {
                Text("Posición del ancla")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(String(format: "%.6f, %.6f",
                            anchor.coordinate.latitude, anchor.coordinate.longitude))
                    .monospacedDigit()
                Text(String(format: "Precisión GPS: ±%.0f m", anchor.horizontalAccuracy))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Radius
            VStack(alignment: .leading, spacing: 10) {
                Text("Radio de borneo")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("Metros", text: $radiusText)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                        .font(.title2)
                        .focused($isFocused)
                    Text("m")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    ForEach(presets, id: \.self) { value in
                        Button("\(value) m") { radiusText = "\(value)" }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                    }
                }
                Text("Distancia que el barco puede alejarse del ancla sin que suene la alarma. Como referencia: cadena o cabo largado + eslora, con un pequeño margen. Entre 5 y 500 m.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            print("[ANCHOR] Setup sheet shown for \(anchor.coordinate.latitude), \(anchor.coordinate.longitude)")
        }
    }
}
