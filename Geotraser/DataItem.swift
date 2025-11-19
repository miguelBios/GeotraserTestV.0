//
//  DataItem.swift
//  GeotraserTestV.0
//
//  Created by Miguel Teperino on 17/10/25.
//

import Foundation
import SwiftData

@Model
class DataItem: Identifiable {
    
    var id: UUID
    var name: String
    var latitude: Double?
    var longitude: Double?
    var timestamp: Date?
    
    init(name: String, latitude: Double? = nil, longitude: Double? = nil, timestamp: Date? = nil) {
        self.id = UUID()
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.timestamp = timestamp
    }
}
