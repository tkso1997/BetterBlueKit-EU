//
//  VehicleStatus.swift
//  BetterBlueKit
//
//  Vehicle status and related nested types
//

import Foundation

// MARK: - Vehicle Status

public struct VehicleStatus: Codable, Sendable {
    public let vin: String
    public var lastUpdated: Date = .init(), syncDate: Date?

    public struct FuelRange: Codable, Sendable {
        public var range: Distance, percentage: Double
        public init(range: Distance, percentage: Double) {
            (self.range, self.percentage) = (range, percentage)
        }
    }

    public var gasRange: FuelRange?
    public struct EVStatus: Codable, Sendable {
        public var charging: Bool, chargeSpeed: Double
        public var pluggedIn: Bool, evRange: FuelRange
        public var chargeLimit: Int?  // Target State of Charge limit (50-100)
        public var estimatedChargingTime: Int?  // Estimated minutes until target SOC is reached

        public init(
            charging: Bool,
            chargeSpeed: Double,
            pluggedIn: Bool,
            evRange: FuelRange,
            chargeLimit: Int? = nil,
            estimatedChargingTime: Int? = nil
        ) {
            (self.charging, self.chargeSpeed, self.pluggedIn, self.evRange) =
                (charging, chargeSpeed, pluggedIn, evRange)
            self.chargeLimit = chargeLimit
            self.estimatedChargingTime = estimatedChargingTime
        }
    }

    public var evStatus: EVStatus?

    // Battery and consumption info
    public var batteryHealth: Int?  // SOH - State of Health (0-100%)
    public var battery12V: Int?  // 12V auxiliary battery level (0-100%)
    public var averageConsumption: Double?  // Average consumption (e.g., kWh/100km)

    public struct Location: Codable, Sendable, Equatable {
        public var latitude: Double, longitude: Double
        public init(latitude: Double, longitude: Double) {
            (self.latitude, self.longitude) = (latitude, longitude)
        }

        public var debug: String { "\(latitude)°, \(longitude)°" }
    }

    public var location: Location
    public enum LockStatus: String, Codable, Sendable {
        case locked, unlocked, unknown

        public init(locked: Bool?) { self = locked == nil ? .unknown : (locked! ? .locked : .unlocked) }

        public mutating func toggle() {
            self = self == .locked ? .unlocked : (self == .unlocked ? .locked : .unknown)
        }
    }

    public var lockStatus: LockStatus
    public struct ClimateStatus: Codable, Sendable {
        public var defrostOn: Bool, airControlOn: Bool
        public var steeringWheelHeatingOn: Bool, temperature: Temperature
        public init(defrostOn: Bool, airControlOn: Bool, steeringWheelHeatingOn: Bool, temperature: Temperature) {
            (self.defrostOn, self.airControlOn, self.steeringWheelHeatingOn, self.temperature) =
                (defrostOn, airControlOn, steeringWheelHeatingOn, temperature)
        }
    }

    public var climateStatus: ClimateStatus, odometer: Distance?

    public init(
        vin: String,
        gasRange: FuelRange? = nil,
        evStatus: EVStatus? = nil,
        location: Location,
        lockStatus: LockStatus,
        climateStatus: ClimateStatus,
        odometer: Distance? = nil,
        syncDate: Date? = nil,
        batteryHealth: Int? = nil,
        battery12V: Int? = nil,
        averageConsumption: Double? = nil
    ) {
        (self.vin, self.gasRange, self.evStatus, self.location) = (vin, gasRange, evStatus, location)
        (self.lockStatus, self.climateStatus, self.odometer, self.syncDate) =
            (lockStatus, climateStatus, odometer, syncDate)
        (self.batteryHealth, self.battery12V, self.averageConsumption) =
            (batteryHealth, battery12V, averageConsumption)
    }
}
