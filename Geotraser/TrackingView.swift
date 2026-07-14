//
//  TrackingView.swift
//  GeotraserTestV.0
//
//  Created by Miguel Teperino on 10/9/25.
//

import SwiftUI
import CoreLocation
import Foundation

struct TrackingView: View {
    let userID: String
    let userDisplayName: String
    @ObservedObject var locationManager: LocationManager
    let grupoid: String? // NEW: the user’s group id
    
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss   // To go back to the first view
    
    @State private var isTrackingActive = false
    @State private var firstRecordedLocation: CLLocation?
    
    @State private var statusMessage: String = ""
    @State private var recorridoID: String? // store the generated recorrido_id per session
    @State private var secuencia: Int = 0   // sequence counter for historic posts
    @State private var isEmergencyActive: Bool = false  // Tracks SOS state
    
    // Offline queue support
    @StateObject private var networkMonitor = NetworkMonitor()
    @State private var lastOfflineSampleAt: Date?
    @State private var isSyncingOfflineQueue = false
    @State private var pendingOfflineCount: Int = 0
    
    // Web view presentation
    @State private var showWeb = false
    
    // Map URLs by grupoid
    private var selectedURL: URL? {
        guard let gid = grupoid?.lowercased(), !gid.isEmpty else { return nil }
        switch gid {
        case "regatas":
            return URL(string: "https://navigationasistance-frontend.vercel.app/maparepew.html")
        case "cavent":
            return URL(string: "https://navigationasistance-frontend.vercel.app/mapaca1.html")
        case "otsudan":
            return URL(string: "https://navigationasistance-frontend.vercel.app/mapaop.html")
        default:
            return nil
        }
    }
    
    private var missingGroupMessage: String {
        "No tiene actividad asignada. Por favor visite www.geotraser.com para visualizar su propio recorrido."
    }
    
    // MARK: - Speed / Heading
    
    // Speed over ground, from GPS, converted m/s -> knots. CLLocation reports -1 when invalid.
    private var speedOverGroundKnots: Double? {
        guard let loc = locationManager.lastLocation, loc.speed >= 0 else { return nil }
        return loc.speed * 1.943844
    }
    
    // Compass device heading (magnetometer, tilt-compensated by the accelerometer inside CoreLocation).
    // Works even when the boat is stationary, unlike GPS course-over-ground.
    private var compassHeadingDegrees: Double? {
        guard let heading = locationManager.heading else { return nil }
        let value = heading.trueHeading >= 0 ? heading.trueHeading : heading.magneticHeading
        return value >= 0 ? value : nil
    }
    
    // Instrument-panel dark background — high contrast, legible in bright sunlight on the water.
    private let panelBackground = Color(red: 0.05, green: 0.09, blue: 0.14)
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("Usuario: \(userDisplayName)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
                
                // MARK: Hero — this is what the sailor should see first: speed & heading,
                // to trim the sails. While not tracking, the entry point takes this slot instead.
                if isTrackingActive {
                    instrumentPanel
                } else {
                    startPrompt
                }
                
                // MARK: SOS — always available, one glance below the instruments.
                sosButton
                
                Divider()
                    .padding(.horizontal, 8)
                
                // MARK: Everything else — secondary controls, tucked away so they don't
                // compete visually with speed / heading / SOS.
                DisclosureGroup("Más opciones") {
                    secondaryControls
                        .padding(.top, 12)
                }
                .tint(.secondary)
                .padding(.horizontal, 4)
            }
            .padding()
        }
        .onAppear {
            locationManager.requestWhenInUseAuthorizationIfNeeded()
            firstRecordedLocation = nil
            Task {
                let count = await OfflineLocationStore.shared.count
                await MainActor.run { pendingOfflineCount = count }
                if networkMonitor.isConnected {
                    await flushOfflineQueueIfNeeded()
                }
            }
        }
        .onDisappear {
            if isTrackingActive {
                locationManager.stopUpdating()
                locationManager.stopUpdatingHeading()
                isTrackingActive = false
            }
        }
        .onChange(of: locationManager.lastLocation) { _, newLocation in
            guard isTrackingActive, let loc = newLocation else { return }
            if firstRecordedLocation == nil {
                firstRecordedLocation = loc
            }
            
            // While offline — or mid-flush, so a live post can't jump ahead of the
            // backlog and scramble the sequence numbers — buffer one sample per
            // minute locally instead of hitting the network.
            if !networkMonitor.isConnected || isSyncingOfflineQueue {
                bufferOfflineSampleIfDue(location: loc )
                return
            }
            
            Task {
                await postPosition(
                    usuarioId: userID,
                    latitude: loc.coordinate.latitude,
                    longitude: loc.coordinate.longitude,
                    heading: compassHeadingDegrees,
                    timestamp: Date()
                )
                await postHistoric(usuarioId: userID, location: loc)
            }
        }
        .onChange(of: networkMonitor.isConnected) { _, isConnected in
            if isConnected {
                Task { await flushOfflineQueueIfNeeded() }
            }
        }
    }
    
    // MARK: - Offline queue
    
    // Called on every GPS update while offline. Only actually stores a sample
    // once 60s have passed since the last one, per "store positions every
    // minute while offline".
    private func bufferOfflineSampleIfDue(location: CLLocation) {
        let now = Date()
        if let last = lastOfflineSampleAt, now.timeIntervalSince(last) < 60 {
            return
        }
        lastOfflineSampleAt = now
        
        guard let rid = recorridoID else { return } // no active recorrido yet — nothing to attach the sample to
        
        let sample = QueuedPosition(
            usuarioId: userID,
            recorridoId: rid,
            capturedAt: now,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude
        )
        
        Task {
            await OfflineLocationStore.shared.append(sample)
            await MainActor.run {
                pendingOfflineCount += 1
                statusMessage = "Sin señal — guardando posición localmente (\(pendingOfflineCount) pendientes)."
            }
        }
    }
    
    // Uploads everything buffered while offline, oldest first, so the
    // recorrido's sequence numbers stay chronological. Stops at the first
    // failure (e.g. connectivity dropped again mid-flush) and leaves the
    // remainder queued for the next reconnect.
    private func flushOfflineQueueIfNeeded() async {
        guard !isSyncingOfflineQueue else { return }
        
        let queued = await OfflineLocationStore.shared.loadAll()
        guard !queued.isEmpty else { return }
        
        isSyncingOfflineQueue = true
        statusMessage = "Señal recuperada — subiendo \(queued.count) posiciones guardadas…"
        
        let ordered = queued.sorted { $0.capturedAt < $1.capturedAt }
        var uploadedIds: Set<UUID> = []
        
        for point in ordered {
            let ok = await postQueuedHistoric(point)
            if ok {
                uploadedIds.insert(point.id)
                pendingOfflineCount = max(0, pendingOfflineCount - 1)
            } else {
                break // still offline, or a transient error — retry on the next reconnect
            }
        }
        
        if !uploadedIds.isEmpty {
            await OfflineLocationStore.shared.remove(ids: uploadedIds)
        }
        
        isSyncingOfflineQueue = false
        statusMessage = uploadedIds.count == ordered.count
            ? "Posiciones sincronizadas."
            : "Sincronización parcial — se reintentará al recuperar señal."
        
        // Anything buffered *during* this flush (network flapping) needs its own pass.
        if networkMonitor.isConnected {
            let remaining = await OfflineLocationStore.shared.count
            if remaining > 0 {
                await flushOfflineQueueIfNeeded()
            }
        }
    }
    
    // MARK: - Hero components
    
    // Big dark instrument card: SOG + heading numerals, plus a rotating compass needle.
    private var instrumentPanel: some View {
        VStack(spacing: 22) {
            HStack(spacing: 0) {
                instrumentStat(title: "VELOCIDAD",
                                value: speedOverGroundKnots.map { String(format: "%.1f", $0) } ?? "—",
                                unit: "kn")
                
                Rectangle()
                    .fill(Color.white.opacity(0.15))
                    .frame(width: 1, height: 84)
                
                instrumentStat(title: "RUMBO",
                                value: compassHeadingDegrees.map { String(format: "%.0f", $0) } ?? "—",
                                unit: "°")
            }
            
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    .frame(width: 76, height: 76)
                Image(systemName: "location.north.fill")
                    .font(.system(size: 30))
                    .foregroundColor(.cyan)
                    .rotationEffect(.degrees(compassHeadingDegrees ?? 0))
                    .animation(.easeInOut(duration: 0.2), value: compassHeadingDegrees)
            }
            
            if locationManager.heading == nil {
                Text("Calibrando brújula…")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.55))
            }
            
            if !networkMonitor.isConnected {
                Label("Sin conexión — guardando posiciones", systemImage: "wifi.slash")
                    .font(.caption)
                    .foregroundColor(.orange)
            } else if pendingOfflineCount > 0 {
                Label("Subiendo \(pendingOfflineCount) posiciones pendientes…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundColor(.cyan)
            }
        }
        .padding(.vertical, 28)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(panelBackground)
        )
    }
    
    private func instrumentStat(title: String, value: String, unit: String) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .tracking(1.5)
                .foregroundColor(.white.opacity(0.55))
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(.white)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text(unit)
                    .font(.title3)
                    .foregroundColor(.white.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity)
    }
    
    // Shown before tracking starts, in the same slot the instrument panel will occupy.
    private var startPrompt: some View {
        VStack(spacing: 14) {
            Image(systemName: "location.circle")
                .font(.system(size: 40))
                .foregroundColor(.white.opacity(0.7))
            Text("Iniciá el seguimiento para ver tu velocidad y rumbo")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.75))
                .multilineTextAlignment(.center)
            
            Button {
                Task { await startTracking() }
            } label: {
                Text("Iniciar seguimiento")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 28)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(panelBackground)
        )
    }
    
    // MARK: - SOS
    
    private var sosButton: some View {
        Button(role: .destructive) {
            let nextState = !isEmergencyActive
            Task {
                let ok = await postEmergency(isActive: nextState)
                if ok {
                    await MainActor.run {
                        isEmergencyActive = nextState
                    }
                }
            }
        } label: {
            Text(isEmergencyActive ? "CANCELAR SOS" : "SOS")
                .font(.title2)
                .fontWeight(.bold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
        }
        .buttonStyle(.borderedProminent)
        .tint(isEmergencyActive ? .orange : .red)
    }
    
    // MARK: - Secondary controls (tucked into "Más opciones")
    
    private var secondaryControls: some View {
        VStack(spacing: 16) {
            if isTrackingActive {
                Button {
                    stopTrackingAndReturn()
                } label: {
                    Text("Detener seguimiento")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            
            Button {
                showWeb = true
            } label: {
                Text("Visualizar Recorrido")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(selectedURL == nil)
            .sheet(isPresented: $showWeb) {
                if let url = selectedURL {
                    SafariView(url: url)
                        .presentationDetents([.fraction(0.85), .large])
                        .presentationDragIndicator(.visible)
                        .presentationBackgroundInteraction(.enabled)
                } else {
                    // Safety: if somehow presented without URL, show message
                    VStack(spacing: 16) {
                        Text(missingGroupMessage)
                            .multilineTextAlignment(.center)
                            .padding()
                        Button("Cerrar") { showWeb = false }
                    }
                    .presentationDetents([.medium, .large])
                }
            }
            
            if let url = selectedURL {
                ShareLink(
                    item: url,
                    subject: Text("Mi recorrido"),
                    message: Text("Podés ver mi recorrido en tiempo real aquí: \(url.absoluteString)")
                ) {
                    Label("Compartir Recorrido", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } else {
                Text(missingGroupMessage)
                    .font(.footnote)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            
            if isTrackingActive, let first = firstRecordedLocation {
                Text(String(format: "Tu recorrido empieza en la posición: %.6f, %.6f",
                            first.coordinate.latitude,
                            first.coordinate.longitude))
                .font(.footnote)
                .multilineTextAlignment(.center)
            }
            
            if isTrackingActive, let rid = recorridoID {
                Text("ID de recorrido: \(rid)")
                    .font(.footnote)
                    .foregroundColor(.primary)
            } else if isTrackingActive, recorridoID == nil {
                Text("Generando ID de recorrido…")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            
            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            
            if pendingOfflineCount > 0 {
                Text("\(pendingOfflineCount) posiciones pendientes de subir")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
            
            // Diagnostics
            VStack(spacing: 4) {
                Text("Estado permiso: \(authDescription(locationManager.authorizationStatus))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Conexión: \(networkMonitor.isConnected ? "En línea" : "Sin conexión")")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let loc = locationManager.lastLocation {
                    Text(String(format: "Última ubicación: %.6f, %.6f @ %@", loc.coordinate.latitude, loc.coordinate.longitude, loc.timestamp.description))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .font(.footnote)
    }
    
    private func authDescription(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "No determinado"
        case .restricted: return "Restringido"
        case .denied: return "Denegado"
        case .authorizedAlways: return "Autorizado siempre"
        case .authorizedWhenInUse: return "Autorizado en uso"
        @unknown default: return "Desconocido"
        }
    }
    
    @MainActor
    private func startTracking() async {
        guard !isTrackingActive else { return }
        
        // Prepare state for a new route
        self.recorridoID = UUID().uuidString // Generate a client-side recorrido_id so every post includes it
        self.secuencia = 0
        self.firstRecordedLocation = nil
        self.isEmergencyActive = false // reset SOS state on new session
        self.lastOfflineSampleAt = nil
        
        // Handle permissions and start location updates
        locationManager.requestAlwaysAuthorizationIfNeeded()
        
        switch locationManager.authorizationStatus {
            case .denied, .restricted:
                statusMessage = "Permiso de ubicación denegado. Habilítelo en Configuración."
                return
            case .notDetermined:
                locationManager.requestWhenInUseAuthorizationIfNeeded()
                try? await Task.sleep(nanoseconds: 800_000_000)
            default:
                break
        }
        locationManager.startUpdating()
        locationManager.startUpdatingHeading() // begin compass updates
        isTrackingActive = true
        if statusMessage.isEmpty {
            statusMessage = "Seguimiento iniciado."
        }
    }
    
    private func stopTrackingAndReturn() {
        guard isTrackingActive else {
            dismiss()
            return
        }
        locationManager.stopUpdating()
        locationManager.stopUpdatingHeading() // stop compass updates
        isTrackingActive = false
        statusMessage = "Seguimiento detenido."
        
        // Notify backend to terminate tracking for this user (real-time table cleanup)
        Task {
            await postDeletePositions(usuarioId: userID)
        }
        
        dismiss()
    }
    
    // MARK: - Real-time position posting (unchanged endpoint)
    private func postPosition(usuarioId: String, latitude: Double, longitude: Double, heading: Double?, timestamp: Date) async {
        guard let url = URL(string: "https://navigationasistance-backend-1.onrender.com/nadadorposicion/agregar") else { return }

        var payload: [String: Any] = [
            "usuarioid": usuarioId,
            "nadadorlat": latitude,
            "nadadorlng": longitude,
            "fechaUltimaActualizacion": Self.actualizarFechaHoraFormatter.string(from: timestamp)
        ]
        if let heading = heading {
            payload["bearing"] = heading ?? NSNull()
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [])
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = data
            request.timeoutInterval = 15

            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                print("[POST RT] Server status: \(http.statusCode)")
            } else {
                print("[POST RT] Position sent OK (bearing: \(heading.map { String($0) } ?? "omitted"))")
            }
        } catch {
            print("[POST RT] Error sending position: \(error.localizedDescription)")
        }
    }
    
    // Call backend to terminate tracking for this user (real-time table)
    private func postDeletePositions(usuarioId: String) async {
        var base = URL(string: "https://navigationasistance-backend-1.onrender.com/nadadorposicion/eliminar")!
        base.appendPathComponent(usuarioId)
        
        var request = URLRequest(url: base)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try? JSONSerialization.data(withJSONObject: [:], options: [])
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                print("[DELETE RT] Server status: \(http.statusCode)")
            } else {
                print("[DELETE RT] Delete request sent OK")
            }
        } catch {
            print("[DELETE RT] Error sending delete: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Emergency (SOS)
    // Returns true if request succeeded (2xx), false otherwise
    private func postEmergency(isActive: Bool) async -> Bool {
        var base = URL(string: "https://navigationasistance-backend-1.onrender.com/nadadorposicion/emergency")!
        base.appendPathComponent(userID)
        
        let payload: [String: Any] = ["emergency": isActive]
        
        do {
            let body = try JSONSerialization.data(withJSONObject: payload, options: [])
            var request = URLRequest(url: base)
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            // Fixed: include the external label `data:`
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            if (200...299).contains(http.statusCode) {
                await MainActor.run {
                    self.statusMessage = isActive ? "SOS enviado correctamente." : "SOS cancelado."
                }
                print("[SOS] OK \(http.statusCode) \(responseBody)")
                return true
            } else {
                await MainActor.run {
                    self.statusMessage = "Error al enviar SOS: \(http.statusCode)"
                }
                print("[SOS] Error \(http.statusCode) \(responseBody)")
                return false
            }
        } catch {
            await MainActor.run {
                self.statusMessage = "Error de red al enviar SOS: \(error.localizedDescription)"
            }
            print("[SOS] Network error: \(error.localizedDescription)")
            return false
        }
    }
}

// MARK: - Networking for historic route creation/posting
private extension TrackingView {
    // Local date (device time zone)
    static let fechaFormatter: DateFormatter = {
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current // local time
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()
    
    // Local date-time with milliseconds (no 'Z')
    static let horaFormatter: DateFormatter = {
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current // local time
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        return df
    }()
    
    static let actualizarFechaHoraFormatter: DateFormatter = {
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return df
    }()
    // Shared historic-point poster used by both the live GPS path and the
    // offline-queue flush, so both write through the exact same request
    // shape and the exact same monotonically increasing `secuencia`.
    // Returns true on a 2xx response.
    func postHistoricPoint(usuarioId: String, recorridoId: String, timestamp: Date, latitude: Double, longitude: Double) async -> Bool {
        guard let url = URL(string: "https://navigationasistance-backend-1.onrender.com/nadadorhistoricorutas/agregar") else { return false }
        
        let fecha = Self.fechaFormatter.string(from: timestamp)
        let hora = Self.horaFormatter.string(from: timestamp)
        
        // Increment sequence per point
        if secuencia == 0 {
            secuencia = 1
        } else {
            secuencia += 1
        }
        
        // Build payload: use snake_case for IDs, keep other keys per Android sample
        let payload: [String: Any] = [
            "usuario_id": usuarioId,
            "recorrido_id": recorridoId,
            "nadadorfecha": fecha,
            "nadadorhora": hora,
            "secuencia": secuencia,
            "nadadorlat": latitude,
            "nadadorlng": longitude
            // TODO: once the backend exposes a heading field (e.g. "nadadorheading"),
            // add it here from `compassHeadingDegrees`. Not sent yet — no endpoint support.
        ]
        
        // Log first payload
        if secuencia == 1 {
            print("[POST HIST] First payload keys: \(Array(payload.keys))")
            print("[POST HIST] First payload: \(payload)")
        }
        
        do {
            let body = try JSONSerialization.data(withJSONObject: payload, options: [])
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            
            let bodyString = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            if secuencia == 1 {
                print("[POST HIST] First response status \(http.statusCode), body: \(bodyString)")
            }
            
            guard (200...299).contains(http.statusCode) else {
                print("[POST HIST] Status \(http.statusCode): \(bodyString)")
                return false
            }
            return true
        } catch {
            print("[POST HIST] Error: \(error.localizedDescription)")
            return false
        }
    }
    
    // Live path: posts immediately as GPS updates arrive while online.
    func postHistoric(usuarioId: String, location: CLLocation) async {
        // Ensure we have a recorridoID (should be set in startTracking)
        if recorridoID == nil {
            await MainActor.run {
                self.recorridoID = UUID().uuidString
            }
        }
        guard let rid = recorridoID else { return }
        
        let ok = await postHistoricPoint(
            usuarioId: usuarioId,
            recorridoId: rid,
            timestamp: Date(),
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude
        )
        if ok {
            await MainActor.run {
                self.statusMessage = "Histórico enviado."
            }
        }
    }
    
    // Offline-queue flush path: posts a buffered sample using its original
    // capture time and recorrido id (not "now"), so the historic record stays
    // accurate even though the upload itself happens minutes later.
    func postQueuedHistoric(_ point: QueuedPosition) async -> Bool {
        await postHistoricPoint(
            usuarioId: point.usuarioId,
            recorridoId: point.recorridoId,
            timestamp: point.capturedAt,
            latitude: point.latitude,
            longitude: point.longitude
        )
    }
}
