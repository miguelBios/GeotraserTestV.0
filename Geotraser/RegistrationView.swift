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
    
    @State private var isSubmitting = false
    @State private var errorMessage: String = ""
    @State private var successMessage: String = ""
    
    @FocusState private var focusedField: Field?
    enum Field { case id, nombre, apellido, email, telefono, password }
    
    var body: some View {
        Form {
            Section(header: Text("Datos de usuario")) {
                TextField("ID (numérico)", text: $id)
                    .keyboardType(.numberPad)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .id)
                
                TextField("Nombre", text: $nombre)
                    .textInputAutocapitalization(.words)
                    .focused($focusedField, equals: .nombre)
                
                TextField("Apellido", text: $apellido)
                    .textInputAutocapitalization(.words)
                    .focused($focusedField, equals: .apellido)
                
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
        !apellido.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        isValidEmail(email) &&
        !telefono.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !password.isEmpty
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
        
        do {
            let ok = try await registerUser(
                id: id.trimmingCharacters(in: .whitespacesAndNewlines),
                nombre: nombre.trimmingCharacters(in: .whitespacesAndNewlines),
                apellido: apellido.trimmingCharacters(in: .whitespacesAndNewlines),
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                telefono: telefono.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password
            )
            if ok {
                successMessage = "Usuario creado correctamente."
                // Return the new ID to the caller to prefill login
                onSuccess(id)
                // Optionally dismiss after a short delay
                try? await Task.sleep(nanoseconds: 900_000_000)
                dismiss()
            } else {
                errorMessage = "No se pudo crear el usuario."
            }
        } catch {
            errorMessage = "Error de red: \(error.localizedDescription)"
        }
        
        isSubmitting = false
    }
}

private func registerUser(id: String,
                          nombre: String,
                          apellido: String,
                          email: String,
                          telefono: String,
                          password: String) async throws -> Bool {
    guard let url = URL(string: "https://navigationasistance-backend-1.onrender.com/usuarios/agregar") else {
        throw URLError(.badURL)
    }
    let payload: [String: Any] = [
        "id": id,
        "nombre": nombre,
        "apellido": apellido,
        "email": email,
        "telefono": telefono,
        "password": password
    ]
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
    // 200..299 is success
    if (200...299).contains(http.statusCode) {
        return true
    } else {
        // Log body for debugging
        let bodyString = String(data: data, encoding: .utf8) ?? ""
        print("[REGISTER] Status \(http.statusCode): \(bodyString)")
        return false
    }
}

#Preview {
    NavigationStack {
        RegistrationView()
    }
}
