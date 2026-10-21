//
//  NetworkMonitor.swift
//  GeotraserTestV.0
//
//  Watches connectivity so TrackingView can switch between posting positions
//  live and buffering them locally while offline. Also exposes which kind of
//  link is in use (wifi / cellular / …) so it can travel with each position.
//

import Foundation
import Network

@MainActor
final class NetworkMonitor: ObservableObject {
    @Published private(set) var isConnected: Bool = true
    @Published private(set) var connectionType: String = "desconocido"

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.geotraser.networkmonitor")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            let type = Self.describe(path)
            Task { @MainActor in
                self?.isConnected = connected
                self?.connectionType = type
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    // "wifi", "celular", "cableada", "otra" or "sin_conexion".
    nonisolated private static func describe(_ path: NWPath) -> String {
        guard path.status == .satisfied else { return "sin_conexion" }
        if path.usesInterfaceType(.wifi) { return "wifi" }
        if path.usesInterfaceType(.cellular) { return "celular" }
        if path.usesInterfaceType(.wiredEthernet) { return "cableada" }
        return "otra"
    }
}
