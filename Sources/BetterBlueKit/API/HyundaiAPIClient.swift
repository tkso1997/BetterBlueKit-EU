// Working - ULTRA-OPTIMIZED VERSION
//  HyundaiEUAPIClient.swift
//  BetterBlueKit
//
//  Created by BetterBlueKit Contributors
//  Hyundai EU API Client Implementation
//
//  ULTRA-OPTIMIZED: Reduced from 1056 to ~750 lines
//  - Unified command execution
//  - JSON parsing helpers
//  - Optimized parser structure
//  - Minimal code duplication

// swiftlint:disable all

import Foundation

// MARK: - JSON Parsing Helpers

private extension Dictionary where Key == String, Value == Any {
    func dict(_ key: String) -> [String: Any] { self[key] as? [String: Any] ?? [:] }
    func int(_ key: String) -> Int? { self[key] as? Int }
    func double(_ key: String) -> Double? { self[key] as? Double }
    func string(_ key: String) -> String? { self[key] as? String }
    func bool(_ key: String) -> Bool { self[key] as? Bool ?? false }
}

// MARK: - Hyundai EU API Endpoint Provider

@MainActor
public final class HyundaiEUAPIEndpointProvider: APIEndpointProvider, @unchecked Sendable {
    private let region: Region
    private let username: String
    private let password: String
    private let pin: String
    private let accountId: UUID
    private var cachedDeviceId: String?
    private var deviceRegistrationTask: Task<String, Error>?
    private var isDeviceRegistered = false
    private var controlToken: String?
    private var controlTokenExpiry: Date?

    // EU-specific constants
    private let baseDomain = "prd.eu-ccapi.hyundai.com"
    private let port = 8080
    private let ccspServiceId = "6d477c38-3ca4-4cf3-9557-2a1929a94654"
    private let ccsServiceSecret = "KUy49XxPzLpLuoK0xhBC77W6VXhmtQR9iQhmIFjjoY4IpxsV"
    private let appId = "014d2225-8495-4735-812d-2616334fd15d"
    private let cfbBase64 = "RFtoRq/vDXJmRndoZaZQyfOot7OrIqGVFj96iY2WL3yyH5Z/pUvlUhqmCxD2t+D65SQ="
    private let loginFormHost = "https://idpconnect-eu.hyundai.com"

    public init(configuration: APIClientConfiguration) {
        (self.region, self.username, self.password, self.pin, self.accountId) =
            (configuration.region, configuration.username, configuration.password,
             configuration.pin, configuration.accountId)
    }

    private var baseURL: String { "https://\(baseDomain):\(port)" }
    private var spaAPIURL: String { "\(baseURL)/api/v1/spa/" }

    // MARK: - Device Registration

    public func ensureDeviceRegistered() async throws {
        guard !isDeviceRegistered else { return }

        if let deviceId = cachedDeviceId {
            print("✅ [HyundaiEUAPI] Device already registered: \(deviceId)")
            isDeviceRegistered = true
            return
        }

        if let task = deviceRegistrationTask {
            cachedDeviceId = try await task.value
        } else {
            cachedDeviceId = try await registerDevice()
        }

        print("✅ [HyundaiEUAPI] Device registered: \(cachedDeviceId ?? "unknown")")
        isDeviceRegistered = true
    }

    private func startDeviceRegistration() {
        guard deviceRegistrationTask == nil else { return }
        deviceRegistrationTask = Task { @MainActor in
            let deviceId = try await self.registerDevice()
            self.cachedDeviceId = deviceId
            self.isDeviceRegistered = true
            print("🔧 [HyundaiEUAPI] Device ID: \(deviceId)")
            return deviceId
        }
    }

    private func registerDevice() async throws -> String {
        let payload: [String: Any] = [
            "pushRegId": String(format: "%064x", arc4random_uniform(UInt32.max)).prefix(64),
            "pushType": "GCM",
            "uuid": UUID().uuidString
        ]

        var request = URLRequest(url: URL(string: "\(spaAPIURL)notifications/register")!)
        request.httpMethod = "POST"
        request.setValue(ccspServiceId, forHTTPHeaderField: "ccsp-service-id")
        request.setValue(appId, forHTTPHeaderField: "ccsp-application-id")
        request.setValue(getStamp(), forHTTPHeaderField: "Stamp")
        request.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deviceId = json.dict("resMsg").string("deviceId") else {
            throw HyundaiKiaAPIError(message: "Device registration failed", apiName: "HyundaiEUAPI")
        }

        return deviceId
    }

    // MARK: - Authentication

    private func getStamp() -> String {
        let rawData = "\(appId):\(Int(Date().timeIntervalSince1970))"
        guard let cfbData = Data(base64Encoded: cfbBase64),
              let rawDataBytes = rawData.data(using: .utf8) else { return "" }
        return Data(zip(cfbData, rawDataBytes).map { $0 ^ $1 }).base64EncodedString()
    }

    private func getAuthorizedHeaders(authToken: AuthToken, vehicle: Vehicle? = nil, stamp: String? = nil, isCCS2: Bool = true) -> [String: String] {
        var headers = [
            "Authorization": authToken.accessToken,
            "ccsp-device-id": cachedDeviceId ?? "",
            "ccsp-application-id": appId,
            "ccsp-service-id": ccspServiceId,
            "Stamp": stamp ?? getStamp(),
            "Content-Type": "application/json;charset=UTF-8",
            "User-Agent": "okhttp/3.12.0"
        ]
        if isCCS2 { headers["ccuCCS2ProtocolSupport"] = "1" }
        return headers
    }

    private func getControlToken(authToken: AuthToken, vehicle: Vehicle) async throws -> String {
        if let token = controlToken, let expiry = controlTokenExpiry, Date() < expiry {
            print("♻️ [HyundaiEUAPI] Using cached control token")
            return token
        }

        print("🔑 [HyundaiEUAPI] Requesting new control token...")

        var request = URLRequest(url: URL(string: "\(baseURL)/api/v1/user/pin")!)
        request.httpMethod = "PUT"

        var headers = getAuthorizedHeaders(authToken: authToken, vehicle: vehicle, stamp: getStamp())
        headers["vehicleId"] = vehicle.regId
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }

        request.httpBody = try JSONSerialization.data(withJSONObject: ["pin": pin, "deviceId": cachedDeviceId ?? ""])

        let (data, response) = try await URLSession.shared.data(for: request)

        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokenValue = json.string("controlToken"),
              let expiresTime = json.int("expiresTime") else {
            throw HyundaiKiaAPIError(message: "Control token request failed", apiName: "HyundaiEUAPI")
        }

        let token = "Bearer \(tokenValue)"
        self.controlToken = token
        self.controlTokenExpiry = Date().addingTimeInterval(TimeInterval(expiresTime))

        print("✅ [HyundaiEUAPI] Control token received (expires in \(expiresTime)s)")
        return token
    }

    // MARK: - Command Execution

    private func pollForCommandCompletion(transactionId: String, vehicle: Vehicle, authToken: AuthToken, maxAttempts: Int = 15, pollInterval: TimeInterval = 2.0) async throws {
        print("⏳ [HyundaiEUAPI] Polling for command completion (msgId: \(transactionId))...")

        for attempt in 1...maxAttempts {
            print("🔄 [HyundaiEUAPI] Poll attempt \(attempt)/\(maxAttempts)")
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))

            var request = URLRequest(url: URL(string: "\(spaAPIURL)notifications/\(vehicle.regId)/records")!)
            request.httpMethod = "GET"
            getAuthorizedHeaders(authToken: authToken, vehicle: vehicle, stamp: getStamp()).forEach {
                request.setValue($1, forHTTPHeaderField: $0)
            }

            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let resMsg = json["resMsg"] as? [[String: Any]] else {
                print("⚠️ [HyundaiEUAPI] Poll request failed, will retry...")
                continue
            }

            for record in resMsg where record.string("recordId") == transactionId {
                if let result = record.string("result") {
                    switch result {
                    case "success":
                        print("✅ [HyundaiEUAPI] Command completed successfully")
                        return
                    case "fail", "non-response":
                        throw HyundaiKiaAPIError(message: "Command failed with result: \(result)", apiName: "HyundaiEUAPI")
                    default:
                        print("⏳ [HyundaiEUAPI] Command in progress: \(result)")
                    }
                }
            }
        }

        throw HyundaiKiaAPIError(message: "Command polling timeout", apiName: "HyundaiEUAPI")
    }

    private func sendCommandWithControlToken(for vehicle: Vehicle, command: VehicleCommand, authToken: AuthToken, commandName: String) async throws {
        print("📤 [HyundaiEUAPI] Sending \(commandName) command...")

        let controlTokenValue = try await getControlToken(authToken: authToken, vehicle: vehicle)
        let endpoint = getEndpointForCommand(command: command, vehicle: vehicle)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"

        var headers = getAuthorizedHeaders(authToken: authToken, vehicle: vehicle, stamp: getStamp())
        headers["Authorization"] = controlTokenValue
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }

        request.httpBody = try JSONSerialization.data(withJSONObject: command.euCommandBody())

        print("🔍 [HyundaiEUAPI] Request URL: \(endpoint.absoluteString)")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msgId = json.string("msgId") else {
            let responseString = String(data: data, encoding: .utf8) ?? "no data"
            throw HyundaiKiaAPIError(message: "\(commandName) command failed: \(responseString)", apiName: "HyundaiEUAPI")
        }

        print("✅ [HyundaiEUAPI] \(commandName) command sent successfully, msgId: \(msgId)")

        try await pollForCommandCompletion(transactionId: msgId, vehicle: vehicle, authToken: authToken)
        print("🎉 [HyundaiEUAPI] \(commandName) command completed!")
    }

    // MARK: - Public Command Methods

    public func sendLockUnlockCommand(for vehicle: Vehicle, command: VehicleCommand, authToken: AuthToken) async throws {
        try await ensureDeviceRegistered()  // Auto-register device
        let commandName = switch command {
        case .lock: "LOCK"
        case .unlock: "UNLOCK"
        default: throw HyundaiKiaAPIError(message: "Invalid lock/unlock command", apiName: "HyundaiEUAPI")
        }
        try await sendCommandWithControlToken(for: vehicle, command: command, authToken: authToken, commandName: commandName)
    }

    public func sendClimateCommand(for vehicle: Vehicle, command: VehicleCommand, authToken: AuthToken) async throws {
        try await ensureDeviceRegistered()  // Auto-register device
        let commandName = switch command {
        case .startClimate: "START CLIMATE"
        case .stopClimate: "STOP CLIMATE"
        default: throw HyundaiKiaAPIError(message: "Invalid climate command", apiName: "HyundaiEUAPI")
        }
        try await sendCommandWithControlToken(for: vehicle, command: command, authToken: authToken, commandName: commandName)
    }

    public func sendChargeCommand(for vehicle: Vehicle, command: VehicleCommand, authToken: AuthToken) async throws {
        try await ensureDeviceRegistered()  // Auto-register device
        let commandName = switch command {
        case .startCharge: "START CHARGE"
        case .stopCharge: "STOP CHARGE"
        default: throw HyundaiKiaAPIError(message: "Invalid charge command", apiName: "HyundaiEUAPI")
        }
        try await sendCommandWithControlToken(for: vehicle, command: command, authToken: authToken, commandName: commandName)
    }

    public func setChargeLimit(for vehicle: Vehicle, targetSOC: Int, authToken: AuthToken) async throws {
        try await ensureDeviceRegistered()  // Auto-register device
        guard targetSOC >= 50 && targetSOC <= 100 else {
            throw HyundaiKiaAPIError(message: "Charge limit must be between 50 and 100", apiName: "HyundaiEUAPI")
        }

        print("🔋 [HyundaiEUAPI] Setting charge limit to \(targetSOC)%...")

        var request = URLRequest(url: URL(string: "\(spaAPIURL)vehicles/\(vehicle.regId)/charge/target")!)
        request.httpMethod = "POST"
        getAuthorizedHeaders(authToken: authToken, vehicle: vehicle, stamp: getStamp()).forEach {
            request.setValue($1, forHTTPHeaderField: $0)
        }

        let body: [String: Any] = [
            "targetSOClist": [
                ["plugType": 0, "targetSOClevel": targetSOC],
                ["plugType": 1, "targetSOClevel": targetSOC]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json.string("retCode") == "S" else {
            throw HyundaiKiaAPIError(message: "Set charge limit failed", apiName: "HyundaiEUAPI")
        }

        print("✅ [HyundaiEUAPI] Charge limit set to \(targetSOC)%")
    }

    private func getEndpointForCommand(command: VehicleCommand, vehicle: Vehicle) -> URL {
        let path = switch command {
        case .unlock, .lock: "door"
        case .startClimate, .stopClimate: "temperature"
        case .startCharge, .stopCharge: "charge"
        }
        return URL(string: "https://\(baseDomain):\(port)/api/v2/spa/vehicles/\(vehicle.regId)/ccs2/control/\(path)")!
    }

    // MARK: - APIEndpointProvider Protocol

    public func loginEndpoint() -> APIEndpoint {
        let loginParams = [
            "grant_type=refresh_token",
            "refresh_token=\(password)",
            "client_id=\(ccspServiceId)",
            "client_secret=\(ccsServiceSecret)"
        ].joined(separator: "&")

        return APIEndpoint(
            url: "\(loginFormHost)/auth/api/v2/user/oauth2/token",
            method: .POST,
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: loginParams.data(using: .utf8)
        )
    }

    public func fetchVehiclesEndpoint(authToken: AuthToken) -> APIEndpoint {
        APIEndpoint(url: "\(spaAPIURL)vehicles", method: .GET,
                   headers: getAuthorizedHeaders(authToken: authToken, stamp: getStamp()))
    }

    public func fetchVehicleStatusEndpoint(for vehicle: Vehicle, authToken: AuthToken) -> APIEndpoint {
        let isCCS2 = vehicle.generation >= 2
        let endpoint = isCCS2 ? "ccs2/carstatus/latest" : "status/latest"
        return APIEndpoint(
            url: "\(spaAPIURL)vehicles/\(vehicle.regId)/\(endpoint)",
            method: .GET,
            headers: getAuthorizedHeaders(authToken: authToken, vehicle: vehicle, stamp: getStamp(), isCCS2: isCCS2)
        )
    }

    public func sendCommandEndpoint(for vehicle: Vehicle, command: VehicleCommand, authToken: AuthToken) -> APIEndpoint {
        APIEndpoint(
            url: getEndpointForCommand(command: command, vehicle: vehicle).absoluteString,
            method: .POST,
            headers: getAuthorizedHeaders(authToken: authToken, vehicle: vehicle, stamp: getStamp()),
            body: try? JSONSerialization.data(withJSONObject: command.euCommandBody())
        )
    }

    // MARK: - Response Parsing

    public func parseLoginResponse(_ data: Data, headers: [String: String]) throws -> AuthToken {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokenType = json.string("token_type"),
              let accessToken = json.string("access_token"),
              let expiresIn = json.int("expires_in") else {
            throw HyundaiKiaAPIError(message: "Invalid login response for \(username)", apiName: "HyundaiEUAPI")
        }

        startDeviceRegistration()

        return AuthToken(
            accessToken: "\(tokenType) \(accessToken)",
            refreshToken: password,
            expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn)),
            pin: pin
        )
    }

    public func parseVehiclesResponse(_ data: Data) throws -> [Vehicle] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vehicleArray = json.dict("resMsg")["vehicles"] as? [[String: Any]] else {
            throw HyundaiKiaAPIError(message: "Invalid vehicles response", apiName: "HyundaiEUAPI")
        }

        return vehicleArray.compactMap { vehicleData in
            guard let vehicleId = vehicleData.string("vehicleId"),
                  let vin = vehicleData.string("vin"),
                  let nickname = vehicleData.string("nickname"),
                  let vehicleName = vehicleData.string("vehicleName") else { return nil }

            return Vehicle(
                vin: vin,
                regId: vehicleId,
                model: nickname.isEmpty ? vehicleName : nickname,
                accountId: accountId,
                isElectric: vehicleData.string("type") == "EV",
                generation: vehicleData.int("generation") ?? 2,
                odometer: Distance(length: 0, units: .kilometers)
            )
        }
    }

    public func parseVehicleStatusResponse(_ data: Data, for vehicle: Vehicle) throws -> VehicleStatus {
        let isCCS2 = vehicle.generation >= 2
        let statusData = try extractStatusData(from: data, isCCS2: isCCS2)
        let parser = HyundaiEUStatusParser(statusData: statusData, vehicle: vehicle, isCCS2: isCCS2)

        return VehicleStatus(
            vin: vehicle.vin,
            gasRange: nil,  // EV only - no gas range
            evStatus: parser.parseEVStatus(),
            location: parser.parseLocation(),
            lockStatus: parser.parseLockStatus(),
            climateStatus: parser.parseClimateStatus(),
            odometer: parser.parseOdometer(),
            syncDate: parser.parseSyncDate(),
            batteryHealth: parser.parseBatteryHealth(),
            battery12V: parser.parseBattery12V(),
            averageConsumption: parser.parseAverageConsumption()
        )
    }

    private func extractStatusData(from data: Data, isCCS2: Bool) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HyundaiKiaAPIError(message: "Invalid status response", apiName: "HyundaiEUAPI")
        }

        let resMsg = json.dict("resMsg")

        if isCCS2 {
            let vehicleState = resMsg.dict("state").dict("Vehicle")
            guard !vehicleState.isEmpty else {
                throw HyundaiKiaAPIError(message: "Invalid CCS2 status structure", apiName: "HyundaiEUAPI")
            }
            return vehicleState
        } else {
            let vehicleStatus = resMsg.dict("vehicleStatusInfo").dict("vehicleStatus")
            guard !vehicleStatus.isEmpty else {
                throw HyundaiKiaAPIError(message: "Invalid status structure", apiName: "HyundaiEUAPI")
            }
            return vehicleStatus
        }
    }

    public func parseCommandResponse(_ data: Data) throws {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HyundaiKiaAPIError(message: "Invalid command response", apiName: "HyundaiEUAPI")
        }

        if let errorCode = json.string("errorCode"), errorCode != "0000" {
            let errorMessage = json.string("errorMessage") ?? "Unknown error"
            throw HyundaiKiaAPIError(message: "Command failed: \(errorCode) - \(errorMessage)", apiName: "HyundaiEUAPI")
        }
    }
}

// MARK: - Status Parser

private struct HyundaiEUStatusParser {
    let statusData: [String: Any]
    let vehicle: Vehicle
    let isCCS2: Bool

    // Shared drivetrain/fuel system access
    private var drivetrain: [String: Any] { statusData.dict("Drivetrain") }
    private var fuelSystem: [String: Any] { drivetrain.dict("FuelSystem") }
    private var dte: [String: Any] { fuelSystem.dict("DTE") }

    func parseEVStatus() -> VehicleStatus.EVStatus? {
        guard vehicle.isElectric else { return nil }
        return isCCS2 ? parseEVStatusCCS2() : parseEVStatusStandard()
    }

    private func parseEVStatusCCS2() -> VehicleStatus.EVStatus? {
        let green = statusData.dict("Green")
        let batteryMgmt = green.dict("BatteryManagement")
        guard let ratio = batteryMgmt.dict("BatteryRemain").double("Ratio") else { return nil }

        let chargingInfo = green.dict("ChargingInformation")
        let charging = chargingInfo.dict("Charging")

        // RemainTime is the remaining charging time in minutes
        let remainTime = charging.int("RemainTime") ?? 0

        // ConnectorFastening.State indicates if plug is connected
        let connectorState = chargingInfo.dict("ConnectorFastening").int("State") ?? 0
        let isPluggedIn = connectorState > 0

        // isCharging is true when plug is connected AND remainTime > 0 (matching TypeScript implementation)
        let isCharging = isPluggedIn && remainTime > 0

        // DEBUG: Print all available charging data
        print("🔋 [DEBUG] ===== CHARGING TIME DEBUG =====")
        print("🔋 [DEBUG] ConnectorFastening.State: \(connectorState)")
        print("🔋 [DEBUG] Charging.RemainTime: \(remainTime) minutes")
        print("🔋 [DEBUG] isPluggedIn: \(isPluggedIn), isCharging: \(isCharging)")

        let estimatedTime = chargingInfo.dict("EstimatedTime")
        print("🔋 [DEBUG] EstimatedTime dict: \(estimatedTime)")
        if let standard = estimatedTime.int("Standard") {
            print("🔋 [DEBUG] EstimatedTime.Standard: \(standard) minutes")
        }
        if let etc = estimatedTime.int("ETC") {
            print("🔋 [DEBUG] EstimatedTime.ETC: \(etc) minutes")
        }
        if let fast = estimatedTime.int("Fast") {
            print("🔋 [DEBUG] EstimatedTime.Fast: \(fast) minutes")
        }
        print("🔋 [DEBUG] ===== END CHARGING DEBUG =====")

        // Parse charge speed from SmartGrid.RealTimePower (matching TypeScript implementation)
        // Path: Green.Electric.SmartGrid.RealTimePower
        let chargeSpeed: Double = {
            // Only check for charging power if actually charging
            guard isCharging else { return 0 }

            let electric = green.dict("Electric")
            let smartGrid = electric.dict("SmartGrid")

            if let realTimePower = smartGrid.double("RealTimePower") {
                print("✅ [DEBUG] Found RealTimePower: \(realTimePower) kW")
                return realTimePower
            }

            print("⚠️ [DEBUG] No charge speed found (RealTimePower not available)")
            return 0
        }()

        // Fallback for isPluggedIn: ChargingDoor.State != 2
        let chargingDoorState = green.dict("ChargingDoor").int("State") ?? 2
        let isPluggedInFallback = chargingDoorState != 2

        let chargeLimit = chargingInfo.dict("TargetSoC").int("Standard")

        // Use RemainTime as the estimated charging time (this is the remaining minutes)
        let estimatedChargingTime: Int? = remainTime > 0 ? remainTime : nil

        let total = dte.int("Total") ?? 0
        let rangeUnit: Distance.Units = (dte.int("Unit") ?? 1) == 1 ? .kilometers : .miles

        print("🔋 [DEBUG] Final values: chargeSpeed=\(chargeSpeed) kW, charging=\(isCharging), remainTime=\(remainTime) min, pluggedIn=\(isPluggedIn || isPluggedInFallback)")

        return VehicleStatus.EVStatus(
            charging: isCharging,
            chargeSpeed: chargeSpeed,
            pluggedIn: isPluggedIn || isPluggedInFallback,
            evRange: VehicleStatus.FuelRange(
                range: Distance(length: Double(total), units: rangeUnit),
                percentage: ratio
            ),
            chargeLimit: chargeLimit,
            estimatedChargingTime: estimatedChargingTime
        )
    }

    private func parseEVStatusStandard() -> VehicleStatus.EVStatus? {
        let evStatusData = statusData.dict("evStatus")
        guard let batteryStatus = evStatusData.int("batteryStatus") else { return nil }

        let drvDistance = evStatusData["drvDistance"] as? [[String: Any]] ?? []
        let rangeValue: Double
        if let first = drvDistance.first {
            rangeValue = first.dict("rangeByFuel").dict("evModeRange").double("value") ?? 0
        } else {
            rangeValue = 0
        }

        // Parse charge speed from batteryChargeSpeed (in kW)
        let chargeSpeed = evStatusData.double("batteryChargeSpeed") ?? 0

        return VehicleStatus.EVStatus(
            charging: evStatusData.bool("batteryCharge"),
            chargeSpeed: chargeSpeed,  // ✅ Now using actual charge speed!
            pluggedIn: (evStatusData.int("batteryPlugin") ?? 0) != 0,
            evRange: VehicleStatus.FuelRange(
                range: Distance(length: rangeValue, units: .kilometers),
                percentage: Double(batteryStatus)
            ),
            chargeLimit: nil,
            estimatedChargingTime: nil
        )
    }

    func parseOdometer() -> Distance {
        if isCCS2, let odometerValue = drivetrain.double("Odometer") {
            return Distance(length: odometerValue, units: .kilometers)
        } else {
            let odoValue = statusData.dict("odo")
            if let value = odoValue.double("value") {
                let unit: Distance.Units = (odoValue.int("unit") ?? 1) == 1 ? .kilometers : .miles
                return Distance(length: value, units: unit)
            }
        }
        return Distance(length: 0, units: .kilometers)
    }

    func parseLocation() -> VehicleStatus.Location {
        if isCCS2 {
            let geoCoord = statusData.dict("Location").dict("GeoCoord")
            return VehicleStatus.Location(
                latitude: geoCoord.double("Latitude") ?? 0,
                longitude: geoCoord.double("Longitude") ?? 0
            )
        } else {
            let coord = statusData.dict("vehicleLocation").dict("coord")
            return VehicleStatus.Location(
                latitude: coord.double("lat") ?? 0,
                longitude: coord.double("lon") ?? 0
            )
        }
    }

    func parseLockStatus() -> VehicleStatus.LockStatus {
        if isCCS2 {
            let driver = statusData.dict("Cabin").dict("Door").dict("Row1").dict("Driver")
            return VehicleStatus.LockStatus(locked: !(driver.bool("Open")))
        }
        return VehicleStatus.LockStatus(locked: statusData.bool("doorLock"))
    }

    func parseClimateStatus() -> VehicleStatus.ClimateStatus {
        if isCCS2 {
            let driver = statusData.dict("Cabin").dict("HVAC").dict("Row1").dict("Driver")
            let speedLevel = driver.dict("Blower").int("SpeedLevel") ?? 0
            let temperature = driver.dict("Temperature")

            return VehicleStatus.ClimateStatus(
                defrostOn: false,
                airControlOn: speedLevel > 0,
                steeringWheelHeatingOn: false,
                temperature: Temperature(units: temperature.int("Unit"), value: temperature.string("Value"))
            )
        } else {
            let airTemp = statusData.dict("airTemp")
            return VehicleStatus.ClimateStatus(
                defrostOn: statusData.bool("defrost"),
                airControlOn: statusData.bool("airCtrlOn"),
                steeringWheelHeatingOn: (statusData.int("steerWheelHeat") ?? 0) != 0,
                temperature: Temperature(units: airTemp.int("unit"), value: airTemp.string("value"))
            )
        }
    }

    func parseSyncDate() -> Date? {
        let dateString = isCCS2 ? statusData.string("Date") : statusData.string("time")
        guard let dateString = dateString else { return nil }

        let formatter = DateFormatter()
        formatter.dateFormat = isCCS2 ? "yyyyMMddHHmmss.SSS" : "yyyyMMddHHmmss"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: dateString)
    }

    func parseBatteryHealth() -> Int? {
        guard isCCS2, vehicle.isElectric else { return nil }
        return statusData.dict("Green").dict("BatteryManagement").dict("SoH").int("Ratio")
    }

    func parseBattery12V() -> Int? {
        guard isCCS2 else { return nil }
        return statusData.dict("Electronics").dict("Battery").int("Level")
    }

    func parseAverageConsumption() -> Double? {
        guard isCCS2 else { return nil }
        return fuelSystem.dict("AverageFuelEconomy").double("Accumulated")
    }
}

// MARK: - VehicleCommand Extension

private extension VehicleCommand {
    func euCommandBody() -> [String: Any] {
        switch self {
        case .lock: return ["command": "close"]
        case .unlock: return ["command": "open"]
        case .stopClimate, .stopCharge: return ["command": "stop"]
        case .startCharge: return ["command": "start"]
        case .startClimate(let options):
            return [
                "command": "start",
                "drvSeatLoc": "L",
                "hvacTemp": Double(options.temperature.value),
                "tempUnit": options.temperature.units.integer() == 0 ? "C" : "F",
                "hvacTempType": options.climate ? 1 : 0,
                "windshieldFrontDefogState": options.defrost,
                "heating1": options.heating ? 4 : 0
            ]
        }
    }
}

// MARK: - Type Alias & Convenience

public typealias HyundaiEUAPIClient = APIClient<HyundaiEUAPIEndpointProvider>

extension APIClient where Provider == HyundaiEUAPIEndpointProvider {
    public convenience init(config: APIClientConfiguration) {
        self.init(configuration: config, endpointProvider: HyundaiEUAPIEndpointProvider(configuration: config))
    }
}
