// 
//  HyundaiEUAPIClient.swift
//  BetterBlueKit
//
//  Created by BetterBlueKit Contributors
//  Hyundai EU API Client Implementation 

//  supported features: get vehicle informatins plus lock/unlock, start/stop climate, set target SOC  

//  limitations: only tested with Ioniq 5 2025 

// swiftlint:disable all


import Foundation

// MARK: - Hyundai EU API Endpoint Provider

/// Endpoint provider for Hyundai vehicles in the European region
/// Implements the CCS2 protocol and standard BlueLink protocol
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

    // Control token for vehicle commands (cached for ~5 minutes)
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
        self.region = configuration.region
        self.username = configuration.username
        self.password = configuration.password
        self.pin = configuration.pin
        self.accountId = configuration.accountId
    }

    private var baseURL: String {
        "https://\(baseDomain):\(port)"
    }

    private var spaAPIURL: String {
        "\(baseURL)/api/v1/spa/"
    }

    // Start device registration in background - called after login
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

    // Public method to ensure device is registered
    // Will be called automatically by APIClient extension methods
    public func ensureDeviceRegistered() async throws {
        if isDeviceRegistered {
            return
        }

        if let deviceId = cachedDeviceId {
            print("✅ [HyundaiEUAPI] Device already registered: \(deviceId)")
            isDeviceRegistered = true
            return
        }

        if let task = deviceRegistrationTask {
            cachedDeviceId = try await task.value
            print("✅ [HyundaiEUAPI] Device registered from task: \(cachedDeviceId ?? "unknown")")
            isDeviceRegistered = true
        } else {
            cachedDeviceId = try await registerDevice()
            print("✅ [HyundaiEUAPI] Device registered now: \(cachedDeviceId ?? "unknown")")
            isDeviceRegistered = true
        }
    }

    private func getStamp() -> String {
        let timestamp = Int(Date().timeIntervalSince1970)
        let rawData = "\(appId):\(timestamp)"

        guard let cfbData = Data(base64Encoded: cfbBase64),
              let rawDataBytes = rawData.data(using: .utf8) else {
            return ""
        }

        let xorResult = zip(cfbData, rawDataBytes).map { $0 ^ $1 }
        return Data(xorResult).base64EncodedString()
    }

    // MARK: - Control Token for Commands

    /// Gets a control token required for sending vehicle commands
    /// Control token is separate from the regular auth token and is required for lock/unlock/climate/charge commands
    /// Token is cached for ~5 minutes
    private func getControlToken(authToken: AuthToken, vehicle: Vehicle) async throws -> String {
        // Return cached token if still valid
        if let token = controlToken,
           let expiry = controlTokenExpiry,
           Date() < expiry {
            print("♻️ [HyundaiEUAPI] Using cached control token")
            return token
        }

        print("🔑 [HyundaiEUAPI] Requesting new control token...")

        let url = URL(string: "\(baseURL)/api/v1/user/pin")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"

        // Headers
        var headers = getAuthorizedHeaders(authToken: authToken, vehicle: vehicle, stamp: getStamp())
        headers["vehicleId"] = vehicle.regId

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        // Body
        let body: [String: Any] = [
            "pin": pin,
            "deviceId": cachedDeviceId ?? ""
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw HyundaiKiaAPIError(message: "Invalid response", apiName: "HyundaiEUAPI")
        }

        guard httpResponse.statusCode == 200 else {
            print("❌ [HyundaiEUAPI] Control token request failed: \(httpResponse.statusCode)")
            if let responseString = String(data: data, encoding: .utf8) {
                print("❌ [HyundaiEUAPI] Response: \(responseString)")
            }
            throw HyundaiKiaAPIError(
                message: "Control token request failed with status \(httpResponse.statusCode)",
                apiName: "HyundaiEUAPI"
            )
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokenValue = json["controlToken"] as? String,
              let expiresTime = json["expiresTime"] as? Int else {
            print("❌ [HyundaiEUAPI] Invalid control token response")
            throw HyundaiKiaAPIError(
                message: "Invalid control token response",
                apiName: "HyundaiEUAPI"
            )
        }

        // Cache the token
        let token = "Bearer \(tokenValue)"
        let expiry = Date().addingTimeInterval(TimeInterval(expiresTime))
        self.controlToken = token
        self.controlTokenExpiry = expiry

        print("✅ [HyundaiEUAPI] Control token received (expires in \(expiresTime)s)")
        return token
    }

    // MARK: - Command Polling

    /// Polls for command completion after sending a lock/unlock/climate/charge command
    /// Commands return a msgId and we need to poll the notifications API until we get a result
    private func pollForCommandCompletion(
        transactionId: String,
        vehicle: Vehicle,
        authToken: AuthToken,
        maxAttempts: Int = 15,
        pollInterval: TimeInterval = 2.0
    ) async throws {
        print("⏳ [HyundaiEUAPI] Polling for command completion (msgId: \(transactionId))...")

        for attempt in 1...maxAttempts {
            print("🔄 [HyundaiEUAPI] Poll attempt \(attempt)/\(maxAttempts)")

            // Wait before polling
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))

            let url = URL(string: "\(spaAPIURL)notifications/\(vehicle.regId)/records")!
            var request = URLRequest(url: url)
            request.httpMethod = "GET"

            // Headers
            let headers = getAuthorizedHeaders(authToken: authToken, vehicle: vehicle, stamp: getStamp())
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                print("⚠️ [HyundaiEUAPI] Poll request failed, will retry...")
                continue
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let resMsg = json["resMsg"] as? [[String: Any]] else {
                print("⚠️ [HyundaiEUAPI] Invalid poll response, will retry...")
                continue
            }

            // Look for our transaction
            for record in resMsg {
                if let recordId = record["recordId"] as? String, recordId == transactionId {
                    if let result = record["result"] as? String {
                        switch result {
                        case "success":
                            print("✅ [HyundaiEUAPI] Command completed successfully")
                            return
                        case "fail", "non-response":
                            print("❌ [HyundaiEUAPI] Command failed with result: \(result)")
                            throw HyundaiKiaAPIError(
                                message: "Command failed with result: \(result)",
                                apiName: "HyundaiEUAPI"
                            )
                        default:
                            print("⏳ [HyundaiEUAPI] Command in progress: \(result)")
                        }
                    }
                }
            }
        }

        // Max attempts reached
        print("❌ [HyundaiEUAPI] Command polling timeout after \(maxAttempts) attempts")
        throw HyundaiKiaAPIError(
            message: "Command polling timeout",
            apiName: "HyundaiEUAPI"
        )
    }

    private func getHeaders() -> [String: String] {
        [
            "User-Agent": "okhttp/3.12.0",
            "Content-Type": "application/json;charset=UTF-8",
            "Accept": "application/json",
            "Accept-Encoding": "gzip",
            "Connection": "Keep-Alive"
        ]
    }

    private func getAuthorizedHeaders(
        authToken: AuthToken,
        vehicle: Vehicle? = nil,
        stamp: String? = nil,
        isCCS2: Bool = true
    ) -> [String: String] {
        var headers: [String: String] = [:]
        headers["Authorization"] = authToken.accessToken
        headers["ccsp-device-id"] = cachedDeviceId ?? ""
        headers["ccsp-application-id"] = appId
        headers["ccsp-service-id"] = ccspServiceId
        headers["Stamp"] = stamp ?? getStamp()
        headers["Content-Type"] = "application/json;charset=UTF-8"
        headers["User-Agent"] = "okhttp/3.12.0"

        if isCCS2 {
            headers["ccuCCS2ProtocolSupport"] = "1"
        }

        return headers
    }

    private func getEndpointForCommand(command: VehicleCommand, vehicle: Vehicle) -> URL {
        // Use regId (vehicleId) for commands, not VIN
        // IMPORTANT: Lock/Unlock AND Climate must use /api/v2/ instead of /api/v1/
        switch command {
        case .unlock, .lock:
            // EU API requires v2 endpoint for door control
            return URL(string: "https://\(baseDomain):\(port)/api/v2/spa/vehicles/\(vehicle.regId)/ccs2/control/door")!
        case .startClimate, .stopClimate:
            // EU API requires v2 endpoint for climate control
            return URL(string: "https://\(baseDomain):\(port)/api/v2/spa/vehicles/\(vehicle.regId)/ccs2/control/temperature")!
        case .startCharge, .stopCharge:
            return URL(string: "https://\(baseDomain):\(port)/api/v2/spa/vehicles/\(vehicle.regId)/ccs2/control/charge")!
        }
    }

    // MARK: - APIEndpointProvider Protocol

    public func loginEndpoint() -> APIEndpoint {
        // Use the correct login endpoint that works
        let loginURL = "\(loginFormHost)/auth/api/v2/user/oauth2/token"

        let loginParams = [
            "grant_type=refresh_token",
            "refresh_token=\(password)",
            "client_id=\(ccspServiceId)",
            "client_secret=\(ccsServiceSecret)"
        ].joined(separator: "&")

        return APIEndpoint(
            url: loginURL,
            method: .POST,
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: loginParams.data(using: .utf8)
        )
    }

    public func fetchVehiclesEndpoint(authToken: AuthToken) -> APIEndpoint {
        // Note: Device registration will be ensured in parseVehiclesResponse
        APIEndpoint(
            url: "\(spaAPIURL)vehicles",
            method: .GET,
            headers: getAuthorizedHeaders(authToken: authToken, stamp: getStamp())
        )
    }

    public func fetchVehicleStatusEndpoint(for vehicle: Vehicle, authToken: AuthToken) -> APIEndpoint {
        let isCCS2 = vehicle.generation >= 2
        let endpoint = isCCS2 ? "ccs2/carstatus/latest" : "status/latest"

        // Use regId (vehicleId) instead of VIN for the status endpoint
        return APIEndpoint(
            url: "\(spaAPIURL)vehicles/\(vehicle.regId)/\(endpoint)",
            method: .GET,
            headers: getAuthorizedHeaders(authToken: authToken, vehicle: vehicle, stamp: getStamp(), isCCS2: isCCS2)
        )
    }

    public func sendCommandEndpoint(
        for vehicle: Vehicle,
        command: VehicleCommand,
        authToken: AuthToken
    ) -> APIEndpoint {
        let endpoint = getEndpointForCommand(command: command, vehicle: vehicle)
        let requestBody = command.euCommandBody()

        // For lock/unlock commands, we need to use control token instead of regular auth token
        // This will be handled in a custom send method
        return APIEndpoint(
            url: endpoint.absoluteString,
            method: .POST,
            headers: getAuthorizedHeaders(authToken: authToken, vehicle: vehicle, stamp: getStamp()),
            body: try? JSONSerialization.data(withJSONObject: requestBody)
        )
    }

    // MARK: - Custom Command Execution for Lock/Unlock

    /// Custom method to send lock/unlock commands that require control token and polling
    /// This bypasses the normal APIEndpoint flow because lock/unlock has special requirements
    public func sendLockUnlockCommand(
        for vehicle: Vehicle,
        command: VehicleCommand,
        authToken: AuthToken
    ) async throws {
        // Check if this is a lock or unlock command
        switch command {
        case .lock, .unlock:
            break // Continue with lock/unlock logic
        default:
            throw HyundaiKiaAPIError(
                message: "sendLockUnlockCommand can only be used for lock/unlock commands",
                apiName: "HyundaiEUAPI"
            )
        }

        let isLock = if case .lock = command { true } else { false }
        print("📤 [HyundaiEUAPI] Sending \(isLock ? "LOCK" : "UNLOCK") command...")

        // Step 1: Get control token
        let controlTokenValue = try await getControlToken(authToken: authToken, vehicle: vehicle)

        // Step 2: Send the command
        let endpoint = getEndpointForCommand(command: command, vehicle: vehicle)
        let requestBody = command.euCommandBody()

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"

        // Headers - USE CONTROL TOKEN instead of auth token!
        var headers = getAuthorizedHeaders(authToken: authToken, vehicle: vehicle, stamp: getStamp())
        headers["Authorization"] = controlTokenValue  // Override with control token

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        // Body
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        print("🔍 [HyundaiEUAPI] Request URL: \(endpoint.absoluteString)")
        print("🔍 [HyundaiEUAPI] Request Body: \(String(data: request.httpBody!, encoding: .utf8) ?? "")")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw HyundaiKiaAPIError(message: "Invalid response", apiName: "HyundaiEUAPI")
        }

        guard httpResponse.statusCode == 200 else {
            let responseString = String(data: data, encoding: .utf8) ?? "no data"
            print("❌ [HyundaiEUAPI] Command failed: \(httpResponse.statusCode)")
            print("❌ [HyundaiEUAPI] Response: \(responseString)")
            throw HyundaiKiaAPIError(
                message: "Command failed with status \(httpResponse.statusCode): \(responseString)",
                apiName: "HyundaiEUAPI"
            )
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msgId = json["msgId"] as? String else {
            print("❌ [HyundaiEUAPI] No msgId in response")
            throw HyundaiKiaAPIError(message: "No msgId in command response", apiName: "HyundaiEUAPI")
        }

        print("✅ [HyundaiEUAPI] Command sent successfully, msgId: \(msgId)")

        // Step 3: Poll for completion
        try await pollForCommandCompletion(
            transactionId: msgId,
            vehicle: vehicle,
            authToken: authToken
        )

        print("🎉 [HyundaiEUAPI] \(isLock ? "LOCK" : "UNLOCK") command completed!")
    }

    // MARK: - Charge Limit Setting

    /// Sets the target State of Charge (SOC) for charging
    /// This sets the charge limit for both AC (slow) and DC (fast) charging
    /// - Parameters:
    ///   - vehicle: The vehicle to set the charge limit for
    ///   - targetSOC: Target charge percentage (50-100)
    ///   - authToken: Authentication token
    public func setChargeLimit(
        for vehicle: Vehicle,
        targetSOC: Int,
        authToken: AuthToken
    ) async throws {
        guard targetSOC >= 50 && targetSOC <= 100 else {
            throw HyundaiKiaAPIError(
                message: "Charge limit must be between 50 and 100",
                apiName: "HyundaiEUAPI"
            )
        }

        print("🔋 [HyundaiEUAPI] Setting charge limit to \(targetSOC)%...")

        let url = URL(string: "\(spaAPIURL)vehicles/\(vehicle.regId)/charge/target")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        // Headers - NO control token needed, just regular auth
        let headers = getAuthorizedHeaders(authToken: authToken, vehicle: vehicle, stamp: getStamp())
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        // Body - set limit for both AC (plugType 0) and DC (plugType 1)
        let body: [String: Any] = [
            "targetSOClist": [
                ["plugType": 0, "targetSOClevel": targetSOC],  // AC charging
                ["plugType": 1, "targetSOClevel": targetSOC]   // DC fast charging
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        print("🔍 [HyundaiEUAPI] Request URL: \(url.absoluteString)")
        print("🔍 [HyundaiEUAPI] Request Body: \(String(data: request.httpBody!, encoding: .utf8) ?? "")")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw HyundaiKiaAPIError(message: "Invalid response", apiName: "HyundaiEUAPI")
        }

        guard httpResponse.statusCode == 200 else {
            let responseString = String(data: data, encoding: .utf8) ?? "no data"
            print("❌ [HyundaiEUAPI] Set charge limit failed: \(httpResponse.statusCode)")
            print("❌ [HyundaiEUAPI] Response: \(responseString)")
            throw HyundaiKiaAPIError(
                message: "Set charge limit failed with status \(httpResponse.statusCode): \(responseString)",
                apiName: "HyundaiEUAPI"
            )
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let retCode = json["retCode"] as? String,
              retCode == "S" else {
            print("❌ [HyundaiEUAPI] Invalid charge limit response")
            throw HyundaiKiaAPIError(message: "Invalid charge limit response", apiName: "HyundaiEUAPI")
        }

        print("✅ [HyundaiEUAPI] Charge limit set successfully to \(targetSOC)%")
        print("🎉 [HyundaiEUAPI] Charge limit updated!")
    }

    // MARK: - Climate Command Execution

    /// Custom method to send climate start/stop commands that require control token and polling
    /// This bypasses the normal APIEndpoint flow because climate commands have special requirements
    public func sendClimateCommand(
        for vehicle: Vehicle,
        command: VehicleCommand,
        authToken: AuthToken
    ) async throws {
        // Check if this is a climate command
        switch command {
        case .startClimate, .stopClimate:
            break // Continue with climate logic
        default:
            throw HyundaiKiaAPIError(
                message: "sendClimateCommand can only be used for startClimate/stopClimate commands",
                apiName: "HyundaiEUAPI"
            )
        }

        let isStart = if case .startClimate = command { true } else { false }
        print("📤 [HyundaiEUAPI] Sending \(isStart ? "START CLIMATE" : "STOP CLIMATE") command...")

        // Step 1: Get control token
        let controlTokenValue = try await getControlToken(authToken: authToken, vehicle: vehicle)

        // Step 2: Send the command
        let endpoint = getEndpointForCommand(command: command, vehicle: vehicle)
        let requestBody = command.euCommandBody()

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"

        // Headers - USE CONTROL TOKEN instead of auth token!
        var headers = getAuthorizedHeaders(authToken: authToken, vehicle: vehicle, stamp: getStamp())
        headers["Authorization"] = controlTokenValue  // Override with control token

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        // Body
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        print("🔍 [HyundaiEUAPI] Request URL: \(endpoint.absoluteString)")
        print("🔍 [HyundaiEUAPI] Request Body: \(String(data: request.httpBody!, encoding: .utf8) ?? "")")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw HyundaiKiaAPIError(message: "Invalid response", apiName: "HyundaiEUAPI")
        }

        guard httpResponse.statusCode == 200 else {
            let responseString = String(data: data, encoding: .utf8) ?? "no data"
            print("❌ [HyundaiEUAPI] Climate command failed: \(httpResponse.statusCode)")
            print("❌ [HyundaiEUAPI] Response: \(responseString)")
            throw HyundaiKiaAPIError(
                message: "Climate command failed with status \(httpResponse.statusCode): \(responseString)",
                apiName: "HyundaiEUAPI"
            )
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msgId = json["msgId"] as? String else {
            print("❌ [HyundaiEUAPI] No msgId in climate command response")
            throw HyundaiKiaAPIError(message: "No msgId in climate command response", apiName: "HyundaiEUAPI")
        }

        print("✅ [HyundaiEUAPI] Climate command sent successfully, msgId: \(msgId)")

        // Step 3: Poll for completion
        try await pollForCommandCompletion(
            transactionId: msgId,
            vehicle: vehicle,
            authToken: authToken
        )

        print("🎉 [HyundaiEUAPI] \(isStart ? "START CLIMATE" : "STOP CLIMATE") command completed!")
    }

    // MARK: - Charge Command Execution

    /// Custom method to send charge start/stop commands that require control token and polling
    /// This bypasses the normal APIEndpoint flow because charge commands have special requirements
    public func sendChargeCommand(
        for vehicle: Vehicle,
        command: VehicleCommand,
        authToken: AuthToken
    ) async throws {
        // Check if this is a charge command
        switch command {
        case .startCharge, .stopCharge:
            break // Continue with charge logic
        default:
            throw HyundaiKiaAPIError(
                message: "sendChargeCommand can only be used for startCharge/stopCharge commands",
                apiName: "HyundaiEUAPI"
            )
        }

        let isStart = if case .startCharge = command { true } else { false }
        print("📤 [HyundaiEUAPI] Sending \(isStart ? "START CHARGE" : "STOP CHARGE") command...")

        // Step 1: Get control token
        let controlTokenValue = try await getControlToken(authToken: authToken, vehicle: vehicle)

        // Step 2: Send the command
        let endpoint = getEndpointForCommand(command: command, vehicle: vehicle)
        let requestBody = command.euCommandBody()

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"

        // Headers - USE CONTROL TOKEN instead of auth token!
        var headers = getAuthorizedHeaders(authToken: authToken, vehicle: vehicle, stamp: getStamp())
        headers["Authorization"] = controlTokenValue  // Override with control token

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        // Body
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        print("🔍 [HyundaiEUAPI] Request URL: \(endpoint.absoluteString)")
        print("🔍 [HyundaiEUAPI] Request Body: \(String(data: request.httpBody!, encoding: .utf8) ?? "")")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw HyundaiKiaAPIError(message: "Invalid response", apiName: "HyundaiEUAPI")
        }

        guard httpResponse.statusCode == 200 else {
            let responseString = String(data: data, encoding: .utf8) ?? "no data"
            print("❌ [HyundaiEUAPI] Charge command failed: \(httpResponse.statusCode)")
            print("❌ [HyundaiEUAPI] Response: \(responseString)")
            throw HyundaiKiaAPIError(
                message: "Charge command failed with status \(httpResponse.statusCode): \(responseString)",
                apiName: "HyundaiEUAPI"
            )
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msgId = json["msgId"] as? String else {
            print("❌ [HyundaiEUAPI] No msgId in charge command response")
            throw HyundaiKiaAPIError(message: "No msgId in charge command response", apiName: "HyundaiEUAPI")
        }

        print("✅ [HyundaiEUAPI] Charge command sent successfully, msgId: \(msgId)")

        // Step 3: Poll for completion
        try await pollForCommandCompletion(
            transactionId: msgId,
            vehicle: vehicle,
            authToken: authToken
        )

        print("🎉 [HyundaiEUAPI] \(isStart ? "START CHARGE" : "STOP CHARGE") command completed!")
    }

    // MARK: - Response Parsing

    public func parseLoginResponse(_ data: Data, headers: [String: String]) throws -> AuthToken {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokenType = json["token_type"] as? String,
              let accessToken = json["access_token"] as? String,
              let expiresIn = json["expires_in"] as? Int
        else {
            throw HyundaiKiaAPIError(
                message: "Invalid login response for \(username): " +
                "\(String(data: data, encoding: .utf8) ?? "No data")",
                apiName: "HyundaiEUAPI"
            )
        }

        // EU API doesn't return a new refresh_token, use the original one
        let refreshToken = password // Keep using the original refresh token

        // Start device registration in background
        startDeviceRegistration()

        return AuthToken(
            accessToken: "\(tokenType) \(accessToken)",
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn)),
            pin: pin
        )
    }

    private func registerDevice() async throws -> String {
        let registrationId = String(format: "%064x", arc4random_uniform(UInt32.max)).prefix(64)
        let payload: [String: Any] = [
            "pushRegId": String(registrationId),
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

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw HyundaiKiaAPIError(message: "Device registration failed", apiName: "HyundaiEUAPI")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resMsg = json["resMsg"] as? [String: Any],
              let deviceId = resMsg["deviceId"] as? String else {
            throw HyundaiKiaAPIError(message: "Invalid device registration response", apiName: "HyundaiEUAPI")
        }

        return deviceId
    }

    public func parseVehiclesResponse(_ data: Data) throws -> [Vehicle] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resMsg = json["resMsg"] as? [String: Any],
              let vehicleArray = resMsg["vehicles"] as? [[String: Any]]
        else {
            throw HyundaiKiaAPIError(message: "Invalid vehicles response", apiName: "HyundaiEUAPI")
        }

        return vehicleArray.compactMap { vehicleData in
            guard let vehicleId = vehicleData["vehicleId"] as? String,
                  let vin = vehicleData["vin"] as? String,
                  let nickname = vehicleData["nickname"] as? String,
                  let vehicleName = vehicleData["vehicleName"] as? String
            else { return nil }

            let vehicleType = vehicleData["type"] as? String ?? ""
            let generation = (vehicleData["generation"] as? Int) ?? 2

            return Vehicle(
                vin: vin,
                regId: vehicleId,
                model: nickname.isEmpty ? vehicleName : nickname,
                accountId: accountId,
                isElectric: vehicleType == "EV",
                generation: generation,
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
            gasRange: parser.parseGasRange(),
            evStatus: parser.parseEVStatus(),
            location: parser.parseLocation(),
            lockStatus: parser.parseLockStatus(),
            climateStatus: parser.parseClimateStatus(),
            odometer: parser.parseOdometer(),
            syncDate: parser.parseSyncDate()
        )
    }

    private func extractStatusData(from data: Data, isCCS2: Bool) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resMsg = json["resMsg"] as? [String: Any] else {
            throw HyundaiKiaAPIError(message: "Invalid status response", apiName: "HyundaiEUAPI")
        }

        if isCCS2 {
            guard let state = resMsg["state"] as? [String: Any],
                  let vehicleState = state["Vehicle"] as? [String: Any] else {
                throw HyundaiKiaAPIError(message: "Invalid CCS2 status structure", apiName: "HyundaiEUAPI")
            }
            return vehicleState
        } else {
            guard let vehicleStatusInfo = resMsg["vehicleStatusInfo"] as? [String: Any],
                  let vehicleStatus = vehicleStatusInfo["vehicleStatus"] as? [String: Any] else {
                throw HyundaiKiaAPIError(message: "Invalid status structure", apiName: "HyundaiEUAPI")
            }
            return vehicleStatus
        }
    }

    public func parseCommandResponse(_ data: Data) throws {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HyundaiKiaAPIError(message: "Invalid command response", apiName: "HyundaiEUAPI")
        }

        if let errorCode = json["errorCode"] as? String, errorCode != "0000" {
            let errorMessage = json["errorMessage"] as? String ?? "Unknown error"
            throw HyundaiKiaAPIError(
                message: "Command failed: \(errorCode) - \(errorMessage)",
                apiName: "HyundaiEUAPI"
            )
        }
    }
}

// MARK: - Status Parser Helper

private struct HyundaiEUStatusParser {
    let statusData: [String: Any]
    let vehicle: Vehicle
    let isCCS2: Bool

    func parseEVStatus() -> VehicleStatus.EVStatus? {
        guard vehicle.isElectric else { return nil }
        return isCCS2 ? parseEVStatusCCS2() : parseEVStatusStandard()
    }

    private func parseEVStatusCCS2() -> VehicleStatus.EVStatus? {
        guard let green = statusData["Green"] as? [String: Any],
              let batteryMgmt = green["BatteryManagement"] as? [String: Any],
              let batteryRemain = batteryMgmt["BatteryRemain"] as? [String: Any],
              let ratio = batteryRemain["Ratio"] as? Double else { return nil }

        let chargingInfo = green["ChargingInformation"] as? [String: Any] ?? [:]
        let charging = chargingInfo["Charging"] as? [String: Any] ?? [:]
        let isCharging = (charging["RemainTime"] as? Int ?? 0) > 0

        let chargingDoor = green["ChargingDoor"] as? [String: Any] ?? [:]
        let isPluggedIn = (chargingDoor["State"] as? Int ?? 2) != 2

        // Extract charge limit from TargetSoC.Standard (AC charging limit)
        let targetSoC = chargingInfo["TargetSoC"] as? [String: Any]
        let chargeLimit = targetSoC?["Standard"] as? Int

        let drivetrain = statusData["Drivetrain"] as? [String: Any] ?? [:]
        let fuelSystem = drivetrain["FuelSystem"] as? [String: Any] ?? [:]
        let dte = fuelSystem["DTE"] as? [String: Any] ?? [:]
        let total = dte["Total"] as? Int ?? 0
        let rangeUnit = (dte["Unit"] as? Int ?? 1) == 1 ? Distance.Units.kilometers : Distance.Units.miles

        return VehicleStatus.EVStatus(
            charging: isCharging,
            chargeSpeed: 0,
            pluggedIn: isPluggedIn,
            evRange: VehicleStatus.FuelRange(
                range: Distance(length: Double(total), units: rangeUnit),
                percentage: ratio
            ),
            chargeLimit: chargeLimit
        )
    }

    private func parseEVStatusStandard() -> VehicleStatus.EVStatus? {
        guard let evStatusData = statusData["evStatus"] as? [String: Any],
              let batteryStatus = evStatusData["batteryStatus"] as? Int else { return nil }

        let batteryCharge = evStatusData["batteryCharge"] as? Bool ?? false
        let batteryPlugin = (evStatusData["batteryPlugin"] as? Int ?? 0) != 0

        let drvDistance = evStatusData["drvDistance"] as? [[String: Any]] ?? []
        let rangeByFuel = drvDistance.first?["rangeByFuel"] as? [String: Any] ?? [:]
        let evModeRange = rangeByFuel["evModeRange"] as? [String: Any] ?? [:]
        let rangeValue = evModeRange["value"] as? Double ?? 0

        return VehicleStatus.EVStatus(
            charging: batteryCharge,
            chargeSpeed: 0,
            pluggedIn: batteryPlugin,
            evRange: VehicleStatus.FuelRange(
                range: Distance(length: rangeValue, units: .kilometers),
                percentage: Double(batteryStatus)
            ),
            chargeLimit: nil  // Standard protocol doesn't provide charge limit info
        )
    }

    func parseGasRange() -> VehicleStatus.FuelRange? {
        guard !vehicle.isElectric, isCCS2 else { return nil }

        if let drivetrain = statusData["Drivetrain"] as? [String: Any],
           let fuelSystem = drivetrain["FuelSystem"] as? [String: Any],
           let level = fuelSystem["Level"] as? Double,
           let dte = fuelSystem["DTE"] as? [String: Any],
           let total = dte["Total"] as? Int {
            let rangeUnit = (dte["Unit"] as? Int ?? 1) == 1 ? Distance.Units.kilometers : Distance.Units.miles
            return VehicleStatus.FuelRange(
                range: Distance(length: Double(total), units: rangeUnit),
                percentage: level
            )
        }
        return nil
    }

    func parseOdometer() -> Distance {
        if isCCS2 {
            if let drivetrain = statusData["Drivetrain"] as? [String: Any],
               let odometerValue = drivetrain["Odometer"] as? Double {
                return Distance(length: odometerValue, units: .kilometers)
            }
        } else {
            if let odoValue = statusData["odo"] as? [String: Any],
               let value = odoValue["value"] as? Double {
                let unit = (odoValue["unit"] as? Int) == 1 ? Distance.Units.kilometers : Distance.Units.miles
                return Distance(length: value, units: unit)
            }
        }
        return Distance(length: 0, units: .kilometers)
    }

    func parseLocation() -> VehicleStatus.Location {
        if isCCS2 {
            let location = statusData["Location"] as? [String: Any] ?? [:]
            let geoCoord = location["GeoCoord"] as? [String: Any] ?? [:]
            return VehicleStatus.Location(
                latitude: geoCoord["Latitude"] as? Double ?? 0,
                longitude: geoCoord["Longitude"] as? Double ?? 0
            )
        } else {
            let vehicleLocation = statusData["vehicleLocation"] as? [String: Any] ?? [:]
            let coord = vehicleLocation["coord"] as? [String: Any] ?? [:]
            return VehicleStatus.Location(
                latitude: coord["lat"] as? Double ?? 0,
                longitude: coord["lon"] as? Double ?? 0
            )
        }
    }

    func parseLockStatus() -> VehicleStatus.LockStatus {
        if isCCS2 {
            let cabin = statusData["Cabin"] as? [String: Any] ?? [:]
            let door = cabin["Door"] as? [String: Any] ?? [:]
            let row1 = door["Row1"] as? [String: Any] ?? [:]
            let driver = row1["Driver"] as? [String: Any] ?? [:]
            let locked = !(driver["Open"] as? Bool ?? false)
            return VehicleStatus.LockStatus(locked: locked)
        } else {
            return VehicleStatus.LockStatus(locked: statusData["doorLock"] as? Bool)
        }
    }

    func parseClimateStatus() -> VehicleStatus.ClimateStatus {
        if isCCS2 {
            let cabin = statusData["Cabin"] as? [String: Any] ?? [:]
            let hvac = cabin["HVAC"] as? [String: Any] ?? [:]
            let row1 = hvac["Row1"] as? [String: Any] ?? [:]
            let driver = row1["Driver"] as? [String: Any] ?? [:]
            let blower = driver["Blower"] as? [String: Any] ?? [:]
            let speedLevel = blower["SpeedLevel"] as? Int ?? 0

            let temperature = driver["Temperature"] as? [String: Any] ?? [:]
            let tempValue = temperature["Value"] as? String
            let tempUnit = temperature["Unit"] as? Int

            return VehicleStatus.ClimateStatus(
                defrostOn: false,
                airControlOn: speedLevel > 0,
                steeringWheelHeatingOn: false,
                temperature: Temperature(units: tempUnit, value: tempValue)
            )
        } else {
            let airTemp = statusData["airTemp"] as? [String: Any] ?? [:]
            return VehicleStatus.ClimateStatus(
                defrostOn: statusData["defrost"] as? Bool ?? false,
                airControlOn: statusData["airCtrlOn"] as? Bool ?? false,
                steeringWheelHeatingOn: (statusData["steerWheelHeat"] as? Int ?? 0) != 0,
                temperature: Temperature(units: airTemp["unit"] as? Int, value: airTemp["value"] as? String)
            )
        }
    }

    func parseSyncDate() -> Date? {
        if isCCS2 {
            guard let dateString = statusData["Date"] as? String else { return nil }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMddHHmmss.SSS"
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            return formatter.date(from: dateString)
        } else {
            guard let timeString = statusData["time"] as? String else { return nil }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMddHHmmss"
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            return formatter.date(from: timeString)
        }
    }
}

// MARK: - VehicleCommand Extension

private extension VehicleCommand {
    func euCommandBody() -> [String: Any] {
        switch self {
        case .lock:
            return ["command": "close"]

        case .unlock:
            return ["command": "open"]

        case .startClimate(let options):
            // EU API Climate Start - FIXED FORMAT based on working logs
            // IMPORTANT: NO nested "hvacInfo" wrapper - all parameters at top level!
            var body: [String: Any] = [
                "command": "start",
                "drvSeatLoc": "L"  // Left-hand drive for EU
            ]

            // Convert temperature to Double (NOT String!)
            let tempValue = Double(options.temperature.value)

            // Temperature unit as String: "C" or "F"
            // units.integer() returns: 0 = Celsius, 1 = Fahrenheit
            let tempUnit = options.temperature.units.integer() == 0 ? "C" : "F"

            body["hvacTemp"] = tempValue  // Must be Double, not String!
            body["tempUnit"] = tempUnit  // Must be String "C" or "F"
            body["hvacTempType"] = options.climate ? 1 : 0
            body["windshieldFrontDefogState"] = options.defrost
            body["heating1"] = options.heating ? 4 : 0  // 0-4 scale, 4 = max heating

            return body

        case .stopClimate:
            return ["command": "stop"]

        case .startCharge:
            return ["command": "start"]

        case .stopCharge:
            return ["command": "stop"]
        }
    }
}

// MARK: - Type Alias

public typealias HyundaiEUAPIClient = APIClient<HyundaiEUAPIEndpointProvider>

// MARK: - Convenience Initializer

extension APIClient where Provider == HyundaiEUAPIEndpointProvider {
    /// Convenience initializer for Hyundai EU API client
    /// - Parameter config: API client configuration
    public convenience init(config: APIClientConfiguration) {
        let provider = HyundaiEUAPIEndpointProvider(configuration: config)
        self.init(configuration: config, endpointProvider: provider)
    }
}
