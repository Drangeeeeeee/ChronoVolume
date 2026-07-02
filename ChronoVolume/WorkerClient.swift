import Foundation

enum WorkerClientError: Error {
    case invalidURL
    case invalidResponse
    case serverError(String)
}

final class WorkerClient {
    let baseURL: URL
    let session: URLSession

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func hello() async throws -> WorkerHelloResponse {
        try await get(path: "/hello")
    }

    func capabilities() async throws -> WorkerCapabilities {
        try await get(path: "/capabilities")
    }

    func checkSource(_ req: SourceCheckRequest) async throws -> SourceCheckResponse {
        try await post(path: "/source/check", body: req)
    }

    func startJob(_ req: StartDistributedJobRequest) async throws -> GenericOKResponse {
        try await post(path: "/job/start", body: req)
    }

    func progress(jobID: UUID) async throws -> JobProgressResponse {
        try await get(path: "/job/progress?id=\(jobID.uuidString)")
    }

    func result(jobID: UUID) async throws -> JobResultResponse {
        try await get(path: "/job/result?id=\(jobID.uuidString)")
    }

    func cancel(jobID: UUID) async throws -> GenericOKResponse {
        try await post(path: "/job/cancel", body: CancelJobRequest(jobID: jobID))
    }

    private func get<T: Decodable>(path: String) async throws -> T {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw WorkerClientError.invalidURL
        }
        let (data, response) = try await session.data(from: url)
        try validate(response: response)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func post<Body: Encodable, T: Decodable>(path: String, body: Body) async throws -> T {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw WorkerClientError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        try validate(response: response)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func validate(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw WorkerClientError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw WorkerClientError.serverError("HTTP \(http.statusCode)")
        }
    }
}
