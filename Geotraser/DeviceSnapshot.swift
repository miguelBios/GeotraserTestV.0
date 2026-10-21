//
//  DeviceTelemetry.swift
//  GeotraserTestV.0
//
//  Battery and signal readings captured alongside every GPS position, so the
//  portal can show device health per unit and build the coverage map.
//
//  Note on "signal strength": iOS has no public API for cellular signal
//  strength (dBm / RSRP / bars). What we *can* measure honestly is:
//    • which link is in use (wifi / cellular / none),
//    • the cellular radio technology (5G / 4G / 3G / 2G),
//    • the round-trip time of our own last upload (a real quality proxy),
//    • GPS horizontal accuracy (GPS signal quality, in meters).
//

import Foundation
import UIKit
import CoreLocation
import CoreTelephony

struct DeviceSnapshot: Codable, Equatable {
    let batteryPercent: Int?        // 0–100; nil when iOS can't tell (e.g. simulator)
    let isCharging: Bool?           // charging or full on power; nil when unknown
    let lowPowerMode: Bool
    let connectionType: String      // "wifi", "celular", "cableada", "otra", "sin_conexion"
    let radioTechnology: String?    // "5G", "4G", "3G", "2G"; nil without a cellular radio
    let latencyMs: Int?             // RTT of the last successful live upload; nil offline
    let gpsAccuracyMeters: Double?  // CLLocation.horizontalAccuracy; nil when invalid

    // Keys sent to the backend. Values that are unknown are omitted, not sent as null.
    var payload: [String: Any] {
        var p: [String: Any] = [
            "bateria_ahorro": lowPowerMode,
            "red_tipo": connectionType
        ]
        if let batteryPercent { p["bateria"] = batteryPercent }
        if let isCharging { p["bateria_cargando"] = isCharging }
        if let radioTechnology { p["red_tecnologia"] = radioTechnology }
        if let latencyMs { p["red_latencia_ms"] = latencyMs }
        if let gpsAccuracyMeters { p["gps_precision_m"] = (gpsAccuracyMeters * 10).rounded() / 10 }
        return p
    }

    // Short line for the diagnostics section of TrackingView.
    var summary: String {
        let bat = batteryPercent.map { "\($0)%" + (isCharging == true ? " ⚡︎" : "") } ?? "—"
        let net = [connectionType, radioTechnology].compactMap { $0 }.joined(separator: " ")
        let lat = latencyMs.map { " · \($0) ms" } ?? ""
        let gps = gpsAccuracyMeters.map { String(format: " · GPS ±%.0f m", $0) } ?? ""
        return "Batería: \(bat) · Red: \(net)\(lat)\(gps)"
    }
}

@MainActor
enum DeviceTelemetry {
    private static let telephony = CTTelephonyNetworkInfo()

    // Battery monitoring must be switched on before batteryLevel returns real values.
    static func start() {
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    static func snapshot(location: CLLocation?, connectionType: String, latencyMs: Int?) -> DeviceSnapshot {
        let device = UIDevice.current
        if !device.isBatteryMonitoringEnabled { device.isBatteryMonitoringEnabled = true }

        let level = device.batteryLevel  // -1.0 when unknown
        let percent = level >= 0 ? Int((level * 100).rounded()) : nil

        let charging: Bool?
        switch device.batteryState {
        case .charging, .full: charging = true
        case .unplugged: charging = false
        case .unknown: charging = nil
        @unknown default: charging = nil
        }

        let accuracy: Double? = {
            guard let loc = location, loc.horizontalAccuracy >= 0 else { return nil }
            return loc.horizontalAccuracy
        }()

        return DeviceSnapshot(
            batteryPercent: percent,
            isCharging: charging,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            connectionType: connectionType,
            radioTechnology: currentRadioGeneration(),
            latencyMs: connectionType == "sin_conexion" ? nil : latencyMs,
            gpsAccuracyMeters: accuracy
        )
    }

    // Generation of the radio carrying cellular data (works even while on wifi,
    // as long as the SIM is registered). Prefers the data service on dual-SIM phones.
    private static func currentRadioGeneration() -> String? {
        guard let byService = telephony.serviceCurrentRadioAccessTechnology, !byService.isEmpty else { return nil }
        let tech: String?
        if let dataId = telephony.dataServiceIdentifier, let t = byService[dataId] {
            tech = t
        } else {
            tech = byService.values.first
        }
        guard let tech else { return nil }

        switch tech {
        case CTRadioAccessTechnologyNR, CTRadioAccessTechnologyNRNSA:
            return "5G"
        case CTRadioAccessTechnologyLTE:
            return "4G"
        case CTRadioAccessTechnologyWCDMA, CTRadioAccessTechnologyHSDPA, CTRadioAccessTechnologyHSUPA,
             CTRadioAccessTechnologyCDMAEVDORev0, CTRadioAccessTechnologyCDMAEVDORevA,
             CTRadioAccessTechnologyCDMAEVDORevB, CTRadioAccessTechnologyeHRPD:
            return "3G"
        case CTRadioAccessTechnologyGPRS, CTRadioAccessTechnologyEdge, CTRadioAccessTechnologyCDMA1x:
            return "2G"
        default:
            return nil
        }
    }
}