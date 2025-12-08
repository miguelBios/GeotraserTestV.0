//
//  ContentView.swift
//  GeotraserTestV.0
//
//  Created by Miguel Teperino on 10/9/25.
//

import SwiftUI
import SwiftData
import CoreLocation
import Combine

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    
    @Query private var items: [DataItem]
    
    @State private var userID: String = ""
    @State private var password: String = ""
    @State private var isPasswordVisible: Bool = false
    
    @StateObject private var locationManager = LocationManager()
    @State private var isRequestingLocation = false
    @State private var locationStatusMessage: String = ""
    @State private var validationStatusMessage: String = ""
    @State private var fetchedUserName: String?
    @State private var fetchedGrupoId: String?           // NEW: store grupoid after login
    @FocusState private var isUserIDFocused: Bool
    @FocusState private var isPasswordFocused: Bool
    
    // Navigation
    @State private var isAuthenticated = false
    @State private var showRegistration = false
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 50) {
                // Main content
                VStack (spacing:30.0){
                    Image("Image")
                        .imageScale(.small)
                        .foregroundStyle(.tint)
                    
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Ingrese su ID de usuario Geotraser")
                            .font(.headline)
                        TextField("ID de usuario", text: $userID)
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.numberPad)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($isUserIDFocused)
                            .disabled(isAuthenticated)
                        
                        Text("Contraseña")
                            .font(.headline)
                        HStack {
                            Group {
                                if isPasswordVisible {
                                    TextField("Contraseña", text: $password)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                        .textContentType(.password)
                                } else {
                                    SecureField("Contraseña", text: $password)
                                        .textContentType(.password)
                                }
                            }
                            .textFieldStyle(.roundedBorder)
                            .focused($isPasswordFocused)
                            .disabled(isAuthenticated)
                            
                            Button(action: { isPasswordVisible.toggle() }) {
                                Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.borderless)
                            .disabled(isAuthenticated)
                        }
                    }
                    .padding(.horizontal)
                    
                    // Verify + Registrarme
                    HStack(spacing: 12) {
                        Button(action: {
                            isUserIDFocused = false
                            isPasswordFocused = false
                            Task { await verifyCredentials() }
                        }) {
                            Text(isAuthenticated ? "Verificado" : "Verificar credenciales")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isRequestingLocation || userID.isEmpty || password.isEmpty || isAuthenticated)
                        
                        // Modern navigation to registration view using isPresented
                        Button {
                            showRegistration = true
                        } label: {
                            Text("Registrarme")
                        }
                        .buttonStyle(.bordered)
                    }
                    
                    if let name = fetchedUserName {
                        Text("Usuario: \(name)")
                            .font(.subheadline)
                            .foregroundColor(.primary)
                    }
                    
                    if isRequestingLocation {
                        ProgressView("Obteniendo ubicación…")
                    }
                    if !validationStatusMessage.isEmpty {
                        Text(validationStatusMessage)
                            .font(.footnote)
                            .foregroundColor(.red)
                    }
                    if !locationStatusMessage.isEmpty {
                        Text(locationStatusMessage)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    
                    // Diagnostics (optional)
                    VStack(spacing: 4) {
                        Text("Estado permiso: \(authDescription(locationManager.authorizationStatus))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if let err = locationManager.lastError {
                            Text("Último error: \(err.localizedDescription)")
                                .font(.caption2)
                                .foregroundColor(.red)
                        }
                        if let loc = locationManager.lastLocation {
                            Text(String(format: "Última ubicación: %.6f, %.6f @ %@", loc.coordinate.latitude, loc.coordinate.longitude, loc.timestamp.description))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    // Keep or remove your local list
                    List{
                        ForEach (items){ item in
                            HStack{
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.name)
                                    if let lat = item.latitude, let lon = item.longitude {
                                        Text(String(format: "Lat: %.6f, Lon: %.6f", lat, lon))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    if let ts = item.timestamp {
                                        Text(ts.formatted(date: .abbreviated, time: .standard))
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                Button{
                                    updateItem(item)
                                } label: {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                }
                            }
                        }
                        .onDelete { indexes in
                            for index in indexes {
                                deleteItem(items[index])
                            }
                        }
                    }
                    
                    // Visible navigation to TrackingView after authentication
                    if isAuthenticated {
                        NavigationLink(
                            destination: TrackingView(
                                userID: userID,
                                userDisplayName: fetchedUserName ?? userID,
                                locationManager: locationManager,
                                grupoid: fetchedGrupoId // pass grupoid
                            )
                        ) {
                            Text("Continuar")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.horizontal)
                    }
                }
                
                Spacer(minLength: 8)
                
                // Cerrar sesión at the bottom, only after validation
                if isAuthenticated {
                    Button(role: .destructive) {
                        // Clear session state
                        fetchedUserName = nil
                        fetchedGrupoId = nil
                        validationStatusMessage = ""
                        locationStatusMessage = ""
                        password = ""
                        userID = ""
                        isAuthenticated = false
                        isPasswordVisible = false
                        // Optionally also reset any other state here
                    } label: {
                        Text("Cerrar sesión")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .padding(.horizontal)
                }
            }
            .padding(.top)
            .onAppear {
                locationManager.requestWhenInUseAuthorizationIfNeeded()
            }
            // Attach the destination for showRegistration
            .navigationDestination(isPresented: $showRegistration) {
                RegistrationView { newID in
                    // Prefill the login ID once user is created
                    self.userID = newID
                }
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
    
    // MARK: - Login flow
    
    @MainActor
    private func verifyCredentials() async {
        isRequestingLocation = true
        validationStatusMessage = ""
        locationStatusMessage = ""
        fetchedUserName = nil
        fetchedGrupoId = nil
        
        do {
            guard let user = try await fetchUser(by: userID) else {
                validationStatusMessage = "El ID ingresado no es válido."
                password = ""
                isRequestingLocation = false
                return
            }
            guard password == user.password else {
                validationStatusMessage = "Contraseña incorrecta."
                password = ""
                isRequestingLocation = false
                return
            }
            // Safely compose full name ignoring nil/empty apellido
            let last = user.apellido?.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = [user.nombre, (last?.isEmpty == false ? last! : nil)].compactMap { $0 }
            let fullName = parts.joined(separator: " ")
            fetchedUserName = fullName.isEmpty ? user.nombre : fullName
            fetchedGrupoId = user.grupoid // NEW: keep grupoid for TrackingView
            isAuthenticated = true // show logout and "Continuar" button, stay on first view
        } catch {
            validationStatusMessage = "Error validando usuario: \(error.localizedDescription)"
            password = ""
        }
        isRequestingLocation = false
    }
    
    // MARK: - Networking: Fetch user by ID
    private func fetchUser(by id: String) async throws -> Usuario? {
        var base = URL(string: "https://navigationasistance-backend-1.onrender.com/usuarios/listarId/")!
        base.appendPathComponent(id)
        
        var request = URLRequest(url: base)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        
        switch http.statusCode {
        case 200:
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .useDefaultKeys
            do {
                let usuario = try decoder.decode(Usuario.self, from: data)
                return usuario
            } catch {
                if data.isEmpty { return nil }
                let trimmed = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if trimmed.isEmpty || trimmed == "null" || trimmed == "[]" || trimmed == "{}" {
                    return nil
                }
                throw error
            }
        case 404:
            return nil
        default:
            throw NSError(domain: "FetchUser", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Servidor respondió con estado \(http.statusCode)"])
        }
    }
    
    struct Usuario: Decodable {
        let id: String
        let nombre: String
        let apellido: String?   // now optional to accept JSON null
        let email: String
        let password: String
        let rol: String
        let telefono: String
        let grupoid: String?    // NEW: decode group id if present
    }
    
    // SwiftData helpers (unchanged)
    func addItem(latitude: Double?, longitude: Double?, timestamp: Date){
        let item = DataItem(name: userID, latitude: latitude, longitude: longitude, timestamp: timestamp)
        context.insert(item)
    }
    func deleteItem(_ item:DataItem) { context.delete(item) }
    func updateItem(_ item:DataItem){ item.name  = "Updated test item"; try? context.save() }
}

#Preview {
    ContentView()
}
