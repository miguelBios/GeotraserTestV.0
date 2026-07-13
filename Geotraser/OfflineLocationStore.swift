//
//  OfflineLocationStore.swift
//  GeotraserTestV.0
//
//  Persists GPS samples captured while offline (one per minute — see
//  TrackingView) so they survive the app being backgrounded or killed with
//  no signal, and can be uploaded in order once connectivity returns.
//

import Foundation

// A single buffered GPS sample, captured while offline, waiting to be
// uploaded once connectivity returns. Stored as plain values (not
// CLLocation) so it round-trips through JSON cleanly.
struct QueuedPosition: Codable, Identifiable {
    let id: UUID
    let usuarioId: String
    let recorridoId: String
    let capturedAt: Date
    let latitude: Double
    let longitude: Double

    init(usuarioId: String, recorridoId: String, capturedAt: Date, latitude: Double, longitude: Double) {
        self.id = UUID()
        self.usuarioId = usuarioId
        self.recorridoId = recorridoId
        self.capturedAt = capturedAt
        self.latitude = latitude
        self.longitude = longitude
    }
}

// An actor keeps reads/writes serialized so a background flush and a new
// offline sample can never race and corrupt the file on disk.
actor OfflineLocationStore {
    static let shared = OfflineLocationStore()

    private let fileURL: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("offline_positions.json")
    }

    func append(_ position: QueuedPosition) {
        var all = loadAll()
        all.append(position)
        persist(all)
    }

    func loadAll() -> [QueuedPosition] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([QueuedPosition].self, from: data)) ?? []
    }

    // Removes only the given ids (positions confirmed uploaded), keeping
    // anything appended concurrently during a flush.
    func remove(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        var all = loadAll()
        all.removeAll { ids.contains($0.id) }
        persist(all)
    }

    func clearAll() {
        persist([])
    }

    var count: Int {
        loadAll().count
    }

    private func persist(_ positions: [QueuedPosition]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(positions) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
