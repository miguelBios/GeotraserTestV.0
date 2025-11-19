//
//  GeotraserTestV_0App.swift
//  GeotraserTestV.0
//
//  Created by Miguel Teperino on 10/9/25.
//

import SwiftUI
import SwiftData

@main
struct GeotraserTestV_0App: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: DataItem.self)
    }
}
