//
//  RegistrationView.swift
//  GeotraserTestV.0
//
//  Created by Miguel Teperino on 01/12/25.
//

import SwiftUI

struct RegistrationView: View {
    // Return created ID to the caller so login can be prefilled
    var onSuccess: (String) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    
    @State private var id: String = ""
    @State private var nombre: String = ""
    @State private var apellido: String = ""
    @State private var email: String = ""
    @State private var telefono: String = ""
    @State private var password: String = ""
    // New: grupoid (actividad)
    @State private var selectedGrupoId: String = ""
    
    @State private var isSubmitting = false
    @State private var errorMessage: String = ""
    @State private var successMessage: String = ""
    
    @FocusState private var focusedField: Field?
    enum Field { case id, nombre, apellido, email, telefono, password }
    
    // Available groups mapping (value to display name)
    private let grupos: [(id: String, name: String)] = [
        ("cavent", "Aventura, MTB"),
        ("regatas", "Navegacion"),
        ("otsudan", "Security Ops")
    ]
    
    var body: some View {
        Form {
            Section(header: Text("Datos de usuario, no personales")) {
                TextField("ID (numérico)", text: $id)
                    .keyboardType(.numberPad)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .id)
                
                TextField("Alias", text: $nombre)
                    .textInputAutocapitalization(.words)
                    .focused($focusedField, equals: .nombre)
                
                TextField("Email", text: $email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .email)
                
                TextField("Teléfono", text: $telefono)
                    .keyboardType(.phonePad)
                    .focused($focusedField, equals: .telefono)
                
                SecureField("Contraseña", text: $password)
                    .focused($focusedField, equals: .password)
            }
            
            Section(header: Text("Actividad")) {
                Picker("Actividad", selection: $selectedGrupoId) {
                    Text("Seleccione…").tag("")
                    ForEach(grupos, id: \.id) { grupo in
                        Text(grupo.name).tag(grupo.id)
                    }
                }
                .pickerStyle(.menu)
            }
            
            if !errorMessage.isEmpty {
                Section {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.footnote)
                }
            }
            if !successMessage.isEmpty {
                Section {
                    Text(successMessage)
                        .foregroundColor(.green)
                        .font(.footnote)
                }
            }
            
            Section {
                Button {
                    focusedField = nil
                    Task { await submit() }
                } label: {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Text("Crear cuenta")
                    }
                }
                .disabled(isSubmitting || !isFormValid)
            }
        }
        .navigationTitle("Registrarme")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private var isFormValid: Bool {
        !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !nombre.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        isValidEmail(email) &&
        !telefono.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !password.isEmpty &&
        !selectedGrupoId.isEmpty
    }
    
    private func isValidEmail(_ email: String) -> Bool {
        // Simple validation; backend will be source of truth
        email.contains("@") && email.contains(".")
    }
    
    @MainActor
    private func submit() async {
        errorMessage = ""
        successMessage = ""
        isSubmitting = true
        
        let trimmedId = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNombre = nombre.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTelefono = telefono.trimmingCharacters(in: .whitespacesAndNewlines)
        
        do {
            let created = try await registerUser(
                id: trimmedId,
                nombre: trimmedNombre,
                apellido: " ", // Force null apellido
                email: trimmedEmail,
                telefono: trimmedTelefono,
                password: password,
                grupoid: selectedGrupoId
            )
            guard created else {
                errorMessage = "No se pudo crear el usuario."
                isSubmitting = false
                return
            }
            
            // Second step: PUT user group
            let groupUpdated = try await updateUserGroup(userId: trimmedId, grupoid: selectedGrupoId)
            if groupUpdated {
                successMessage = "Usuario creado correctamente."
                // Return the new ID to the caller to prefill login
                onSuccess(trimmedId)
                // Optionally dismiss after a short delay
                try? await Task.sleep(nanoseconds: 900_000_000)
                dismiss()
            } else {
                errorMessage = "Usuario creado, pero no se pudo asignar la actividad."
            }
        } catch {
            errorMessage = "Error de red: \(error.localizedDescription)"
        }
        
        isSubmitting = false
    }
}

private func registerUser(id: String,
                          nombre: String,
                          apellido: String?, // nil means send JSON null
                          email: String,
                          telefono: String,
                          password: String,
                          grupoid: String) async throws -> Bool {
    guard let url = URL(string: "https://navigationasistance-backend-1.onrender.com/usuarios/agregar") else {
        throw URLError(.badURL)
    }
    let payload: [String: Any] = [
        "id": id,
        "nombre": nombre,
        "apellido":" ",
        "email": email,
        "telefono": telefono,
        "password": password,
        "grupoid": grupoid
    ]
    // Force JSON null for apellido
    //payload["apellido"] = NSNull()
    
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
    if (200...299).contains(http.statusCode) {
        return true
    } else {
        let bodyString = String(data: data, encoding: .utf8) ?? ""
        print("[REGISTER] Status \(http.statusCode): \(bodyString)")
        return false
    }
}

// PUT /usuarios/usuarios/{userid}/grupo with grupoid in body
private func updateUserGroup(userId: String, grupoid: String) async throws -> Bool {
    guard var base = URL(string: "https://navigationasistance-backend-1.onrender.com/usuarios/usuarios") else {
        throw URLError(.badURL)
    }
    base.appendPathComponent(userId)
    base.appendPathComponent("grupo")
    
    let payload: [String: Any] = [
        "grupoid": grupoid
    ]
    let body = try JSONSerialization.data(withJSONObject: payload, options: [])
    
    var request = URLRequest(url: base)
    request.httpMethod = "PUT"
    request.timeoutInterval = 20
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = body
    
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
        throw URLError(.badServerResponse)
    }
    if (200...299).contains(http.statusCode) {
        return true
    } else {
        let bodyString = String(data: data, encoding: .utf8) ?? ""
        print("[PUT GROUP] Status \(http.statusCode): \(bodyString)")
        return false
    }
}

#Preview {
    NavigationStack {
        RegistrationView()
    }
}
