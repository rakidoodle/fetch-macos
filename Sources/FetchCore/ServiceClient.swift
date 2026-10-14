import Foundation

public actor ServiceClient {
    public let baseURL: URL
    private let token: String
    private var key = ""
    private let session: URLSession
    public init(port: Int, token: String) {
        self.baseURL = URL(string: "http://127.0.0.1:\(port)")!
        self.token = token
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.connectionProxyDictionary = [:]
        self.session = URLSession(configuration: config)
    }
    public func state() async throws -> ServiceState {
        let data = try await request("api/state")
        let value = try JSONDecoder().decode(ServiceState.self, from: data)
        key = value.key
        return value
    }
    public func add(_ value: AddRequest) async throws -> String {
        if let error = value.validationError { throw ServiceError.message(error) }
        let data = try await request("api/downloads", method: "POST", body: JSONEncoder().encode(value))
        struct Result: Decodable { let id: String }
        return try JSONDecoder().decode(Result.self, from: data).id
    }
    public func action(_ id: String, _ action: String) async throws {
        guard UUID(uuidString: id) != nil, ["pause", "resume", "cancel", "remove"].contains(action) else { throw ServiceError.message("Invalid download action.") }
        _ = try await request("api/downloads/\(id)/\(action)", method: "POST", body: Data("{}".utf8))
    }
    public func settings(_ value: TransferSettings) async throws {
        guard value.isValid else { throw ServiceError.message("Check connections, active downloads, and speed limit.") }
        _ = try await request("api/settings", method: "PUT", body: JSONEncoder().encode(value))
    }
    private func request(_ path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "X-Fetch-Key")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServiceError.message("Download service returned an invalid response.") }
        guard (200..<300).contains(http.statusCode) else {
            struct Failure: Decodable { let error: String }
            let error = (try? JSONDecoder().decode(Failure.self, from: data).error) ?? "Download service request failed (\(http.statusCode))."
            throw ServiceError.message(error)
        }
        return data
    }
}
