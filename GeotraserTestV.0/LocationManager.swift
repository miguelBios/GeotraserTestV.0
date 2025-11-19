//
//  LocationManager.swift
//  GeotraserTestV.0
//
//  Created by Miguel Teperino on 29/10/25.
//

import Foundation
import CoreLocation

@MainActor
final class LocationManager: NSObject, ObservableObject {
    private let manager = CLLocationManager()
    
    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var lastLocation: CLLocation?
    @Published private(set) var lastError: Error?
    
    override init() {
        self.authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        // Accuracy and behavior suitable for continuous/background tracking
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        // We'll enable allowsBackgroundLocationUpdates only when we actually start tracking
        // to avoid unnecessary background usage before user logs in.
    }
    
    func requestWhenInUseAuthorizationIfNeeded() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            break
        }
    }
    
    func requestAlwaysAuthorizationIfNeeded() {
        // If already always, nothing to do.
        // If in-use or not determined, request Always.
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestAlwaysAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
        default:
            break
        }
    }
    
    func requestSingleLocation() {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            self.lastError = NSError(domain: "Location", code: 1, userInfo: [NSLocalizedDescriptionKey: "Location permission not granted"])
        }
    }
    
    // Start continuous updates (supports background if capability + Always auth are granted)
    func startUpdating() {
        // Allow background updates only when tracking is active.
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            self.lastError = NSError(domain: "Location", code: 1, userInfo: [NSLocalizedDescriptionKey: "Location permission not granted"])
        }
    }
    
    // Stop continuous updates
    func stopUpdating() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        manager.showsBackgroundLocationIndicator = false
    }
    
    // Async helper to await one location reading with timeout
    func requestOneLocation(timeout: TimeInterval) async throws -> CLLocation {
        if delegateHandler != nil {
            throw NSError(domain: "Location", code: 3, userInfo: [NSLocalizedDescriptionKey: "Another location request is already in progress"])
        }
        
        if authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        
        return try await withTaskCancellationHandler(operation: {
            try await withThrowingTaskGroup(of: CLLocation.self) { group in
                self.manager.requestLocation()
                
                let locationTask = Task<CLLocation, Error> { [weak self] in
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CLLocation, Error>) in
                        guard let self else {
                            continuation.resume(throwing: CancellationError())
                            return
                        }
                        var safe = SafeOnceContinuation(continuation)
                        let handler = DelegateHandler(
                            onLocation: { [weak self] location in
                                guard let self else { return }
                                if safe.resumeIfNeeded(returning: location) {
                                    self.delegateHandler = nil
                                }
                            },
                            onError: { [weak self] error in
                                guard let self else { return }
                                if safe.resumeIfNeeded(throwing: error) {
                                    self.delegateHandler = nil
                                }
                            }
                        )
                        self.delegateHandler = handler
                    }
                }
                
                let timeoutTask = Task<CLLocation, Error> {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw NSError(domain: "Location", code: 2, userInfo: [NSLocalizedDescriptionKey: "Tiempo de espera agotado al obtener la ubicación"])
                }
                
                group.addTask { try await locationTask.value }
                group.addTask { try await timeoutTask.value }
                
                defer {
                    locationTask.cancel()
                    timeoutTask.cancel()
                    self.delegateHandler = nil
                }
                
                let result = try await group.next()!
                return result
            }
        }, onCancel: {
            Task { @MainActor in
                self.delegateHandler = nil
            }
        })
    }
    
    // MARK: - Internal delegate bridging
    private var delegateHandler: DelegateHandler?
    
    private final class DelegateHandler {
        let onLocation: (CLLocation) -> Void
        let onError: (Error) -> Void
        
        init(onLocation: @escaping (CLLocation) -> Void, onError: @escaping (Error) -> Void) {
            self.onLocation = onLocation
            self.onError = onError
        }
    }
    
    private struct SafeOnceContinuation<T> {
        private var continuation: CheckedContinuation<T, Error>?
        private var resumed = false
        
        init(_ continuation: CheckedContinuation<T, Error>) {
            self.continuation = continuation
        }
        
        mutating func resumeIfNeeded(returning value: T) -> Bool {
            guard !resumed, let cont = continuation else { return false }
            resumed = true
            continuation = nil
            cont.resume(returning: value)
            return true
        }
        
        mutating func resumeIfNeeded(throwing error: Error) -> Bool {
            guard !resumed, let cont = continuation else { return false }
            resumed = true
            continuation = nil
            cont.resume(throwing: error)
            return true
        }
    }
}

extension LocationManager: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.authorizationStatus = manager.authorizationStatus
        }
    }
    
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            self.lastLocation = loc
            self.lastError = nil
            self.delegateHandler?.onLocation(loc)
        }
    }
    
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.lastError = error
            self.delegateHandler?.onError(error)
        }
    }
}
