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
    
    var body: some View {
        VStack(spacing: 50) {
            Image("Image")
                .imageScale(.small)
                .foregroundStyle(.tint)
            
            Text("Usuario: \(userDisplayName)")
                .font(.subheadline)
            
            // Start / Stop / Open Map
            Button {
                Task { await startTracking() }
            } label: {
                Text("Iniciar seguimiento")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isTrackingActive)
            
            Button {
                stopTrackingAndReturn()
            } label: {
                Text("Detener seguimiento")
            }
            .buttonStyle(.bordered)
            .disabled(!isTrackingActive)
            
            // In-app web window button: only enabled if we have a URL from grupoid
            Button {
                showWeb = true
            } label: {
                Text("Visualizar Recorrido")
            }
            .buttonStyle(.borderedProminent)
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
            
            // Share button for the visualization URL
            if let url = selectedURL {
                ShareLink(
                    item: url,
                    subject: Text("Mi recorrido"),
                    message: Text("Podés ver mi recorrido en tiempo real aquí: \(url.absoluteString)")
                ) {
                    Label("Compartir Recorrido", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
            } else {
                // If there is no URL (no/unknown grupoid), show the guidance message inline
                Text(missingGroupMessage)
                    .font(.footnote)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            
            // SOS button (toggles emergency on/off)
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
                Text(isEmergencyActive ? "Cancelar SOS" : "SOS")
            }
            .buttonStyle(.borderedProminent)
            
            // First position label
            if isTrackingActive, let first = firstRecordedLocation {
                VStack(spacing: 6) {
                    Text(String(format: "Tu recorrido empieza en la posición: %.6f, %.6f",
                                first.coordinate.latitude,
                                first.coordinate.longitude))
                    .font(.subheadline)
                }
            }
            
            // Show recorridoID independently so it appears as soon as it’s available
            if isTrackingActive, let rid = recorridoID {
                VStack(spacing: 6){
                    Text("ID de recorrido: \(rid)")
                        .font(.subheadline)
                        .foregroundColor(.primary)
                }
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
            
            // Diagnostics (optional)
            VStack(spacing: 4) {
                Text("Estado permiso: \(authDescription(locationManager.authorizationStatus))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let loc = locationManager.lastLocation {
                    Text(String(format: "Última ubicación: %.6f, %.6f @ %@", loc.coordinate.latitude, loc.coordinate.longitude, loc.timestamp.description))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .onAppear {
            locationManager.requestWhenInUseAuthorizationIfNeeded()
            firstRecordedLocation = nil
        }
        .onDisappear {
            if isTrackingActive {
                locationManager.stopUpdating()
                isTrackingActive = false
            }
        }
        .onChange(of: locationManager.lastLocation) { _, newLocation in
            guard isTrackingActive, let loc = newLocation else { return }
            if firstRecordedLocation == nil {
                firstRecordedLocation = loc
            }
            Task {
                // Optional: keep real-time positions table
                await postPosition(usuarioId: userID, latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude)
                // Historic routes table: post EVERY update, full payload
                await postHistoric(usuarioId: userID, location: loc)
            }
        }
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
        isTrackingActive = false
        statusMessage = "Seguimiento detenido."
        
        // Notify backend to terminate tracking for this user (real-time table cleanup)
        Task {
            await postDeletePositions(usuarioId: userID)
        }
        
        dismiss()
    }
    
    // MARK: - Real-time position posting (unchanged endpoint)
    private func postPosition(usuarioId: String, latitude: Double, longitude: Double) async {
        guard let url = URL(string: "https://navigationasistance-backend-1.onrender.com/nadadorposicion/agregar") else { return }
        let payload: [String: Any] = [
            "usuarioid": usuarioId,
            "nadadorlat": latitude,
            "nadadorlng": longitude
        ]
        
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
                print("[POST RT] Position sent OK")
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
    
    // Post one historic record. Always include recorrido_id so first post == rest.
    func postHistoric(usuarioId: String, location: CLLocation) async {
        guard let url = URL(string: "https://navigationasistance-backend-1.onrender.com/nadadorhistoricorutas/agregar") else { return }
        
        // Ensure we have a recorridoID (should be set in startTracking)
        if recorridoID == nil {
            await MainActor.run {
                self.recorridoID = UUID().uuidString
            }
        }
        guard let rid = recorridoID else { return }
        
        // Prepare common fields
        let now = Date()
        let fecha = Self.fechaFormatter.string(from: now) // local yyyy-MM-dd
        let hora = Self.horaFormatter.string(from: now)   // local yyyy-MM-dd'T'HH:mm:ss.SSS
        
        // Increment sequence per point
        if secuencia == 0 {
            secuencia = 1
        } else {
            secuencia += 1
        }
        
        // Build payload: use snake_case for IDs, keep other keys per Android sample
        let payload: [String: Any] = [
            "usuario_id": usuarioId,
            "recorrido_id": rid,
            "nadadorfecha": fecha,
            "nadadorhora": hora,
            "secuencia": secuencia,
            "nadadorlat": location.coordinate.latitude,
            "nadadorlng": location.coordinate.longitude
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
            
            if !(200...299).contains(http.statusCode) {
                print("[POST HIST] Status \(http.statusCode): \(bodyString)")
                return
            }
            
            // Success: optional UI message
            await MainActor.run {
                self.statusMessage = "Histórico enviado."
            }
        } catch {
            print("[POST HIST] Error: \(error.localizedDescription)")
        }
    }
}
