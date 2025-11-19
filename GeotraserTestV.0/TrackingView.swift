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
    
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss   // To go back to the first view
    
    @State private var isTrackingActive = false
    @State private var firstRecordedLocation: CLLocation?
    @State private var lastPostDate: Date?
    private let postThrottleInterval: TimeInterval = 5 // seconds
    
    @State private var statusMessage: String = ""
    @State private var recorridoID: String? // store the generated recorridoid
    
    var body: some View {
        VStack(spacing: 20) {
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
            
            Button {
                if let url = URL(string: "https://navigationasistance-frontend.vercel.app/mapa.html#") {
                    openURL(url)
                }
            } label: {
                Text("Abrir mapa")
            }
            .buttonStyle(.bordered)
            
            // First position label
            if isTrackingActive, let first = firstRecordedLocation {
                Text(String(format: "Tu recorrido empieza en la posición: %.6f, %.6f",
                            first.coordinate.latitude,
                            first.coordinate.longitude))
                .font(.subheadline)
            }
            
            if let rid = recorridoID {
                Text("su ID de recorrido es: \(rid)")
                    .font(.subheadline)
                    .foregroundColor(.primary)
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
            // Throttle remote posts (nadadorposicion/agregar)
            if let last = lastPostDate, Date().timeIntervalSince(last) < postThrottleInterval {
                return
            }
            lastPostDate = Date()
            Task {
                await postPosition(usuarioId: userID, latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude)
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
        
        // 1) Create recorrido and get recorridoid before starting GPS updates
        do {
            let record = try await crearRecorrido(usuarioId: userID)
            self.recorridoID = record.recorridoid
            self.statusMessage = "su ID de recorrido es: \(record.recorridoid)"
        } catch {
            let nsError = error as NSError
            self.statusMessage = "No se pudo crear el recorrido: \(nsError.domain) (\(nsError.code)) \(nsError.localizedDescription)"
            return
        }
        
        // 2) Handle permissions and start location updates
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
        
        // Notify backend to terminate tracking for this user
        Task {
            await postDeletePositions(usuarioId: userID)
        }
        
        dismiss()
    }
    
    private func postPosition(usuarioId: String, latitude: Double, longitude: Double) async {
        guard let url = URL(string: "https://navigationasistance-backend-1.onrender.com/nadadorposicion/agregar") else { return }
        let payload: [String: String] = [
            "usuarioid": usuarioId,
            "nadadorlat": String(latitude),
            "nadadorlng": String(longitude)
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
                print("[POST] Server status: \(http.statusCode)")
            } else {
                print("[POST] Position sent OK")
            }
        } catch {
            print("[POST] Error sending position: \(error.localizedDescription)")
        }
    }
    
    // Call backend to terminate tracking for this user
    private func postDeletePositions(usuarioId: String) async {
        var base = URL(string: "https://navigationasistance-backend-1.onrender.com/nadadorposicion/eliminar")!
        base.appendPathComponent(usuarioId)
        
        var request = URLRequest(url: base)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        
        // If your backend requires a body, add it here. Currently sending empty JSON.
        request.httpBody = try? JSONSerialization.data(withJSONObject: [:], options: [])
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                print("[DELETE POST] Server status: \(http.statusCode)")
            } else {
                print("[DELETE POST] Delete request sent OK")
            }
        } catch {
            print("[DELETE POST] Error sending delete: \(error.localizedDescription)")
        }
    }
}

// MARK: - Networking for recorrido creation
private extension TrackingView {
    // Matches the JSON you provided
    struct NadadorHistoricoRutaRecord: Decodable {
        let usuarioid: String
        let recorridoid: String
        let nadadorfecha: String
        let nadadorhora: String
        let secuencia: Int
        let nadadorlat: String
        let nadadorlng: String
    }
    
    // Posts to the external library to create a recorrido and returns the full record
    func crearRecorrido(usuarioId: String) async throws -> NadadorHistoricoRutaRecord {
        // Try HTTP first if HTTPS:8082 is failing
        guard let url = URL(string: "https://navigationasistance-backend-1.onrender.com/nadadorhistoricorutas/agregar") else {
            throw URLError(.badURL)
        }
        
        let payload: [String: String] = [
            "usuarioid": usuarioId
        ]
        
        let body = try JSONSerialization.data(withJSONObject: payload, options: [])
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            guard (200...299).contains(http.statusCode) else {
                let message = String(data: data, encoding: .utf8) ?? ""
                throw NSError(domain: "CrearRecorrido", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Estado \(http.statusCode): \(message)"])
            }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .useDefaultKeys
            return try decoder.decode(NadadorHistoricoRutaRecord.self, from: data)
        } catch {
            // Log extra info for diagnosis
            let nsError = error as NSError
            print("[CrearRecorrido] URL: \(url.absoluteString)")
            print("[CrearRecorrido] Error: \(nsError.domain) (\(nsError.code)) \(nsError.localizedDescription)")
            throw error
        }
    }
}
