import Foundation
import SwiftUI
#if !CLI
import GoogleSignIn
#endif

final class EmbeddingService: @unchecked Sendable {
    enum ContentPart {
        case text(String)
        case file(uri: String, mimeType: String)
        
        var dictionaryValue: [String: Any] {
            switch self {
            case .text(let text):
                return ["text": text]
            case .file(let uri, let mimeType):
                return ["file_data": ["file_uri": uri, "mime_type": mimeType]]
            }
        }
    }

    private var apiKey: String {
        UserDefaults.standard.string(forKey: "userAPIKey") ?? ""
    }
    private var gcpProjectID: String {
        UserDefaults.standard.string(forKey: "gcpProjectID") ?? "generative-bazaar-001"
    }
    private var gcpLocation: String {
        UserDefaults.standard.string(forKey: "gcpLocation") ?? "us-central1"
    }
    
    init() {}
    
    func getEmbedding(for text: String, authToken: String? = nil, projectID: String? = nil, location: String? = nil) async throws -> [Float] {
        return try await getEmbedding(for: [.text(text)], authToken: authToken, projectID: projectID, location: location)
    }

    func getEmbedding(for parts: [ContentPart], authToken: String? = nil, projectID: String? = nil, location: String? = nil) async throws -> [Float] {
        let key = apiKey
        let project = projectID ?? gcpProjectID
        let loc = location ?? gcpLocation
        
        if let token = authToken {
            return try await getVertexEmbedding(for: parts, projectID: project, location: loc, token: token)
        }
        
        if !project.isEmpty {
            // Use Vertex AI (BYOC)
            #if CLI
            throw NSError(domain: "EmbeddingService", code: 4, userInfo: [NSLocalizedDescriptionKey: "Authentication required for CLI (provide authToken)."])
            #else
            guard let user = await MainActor.run(body: { GIDSignIn.sharedInstance.currentUser }) else {
                throw NSError(domain: "EmbeddingService", code: 4, userInfo: [NSLocalizedDescriptionKey: "Not signed in to Google."])
            }
            
            let token = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                user.refreshTokensIfNeeded { user, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else if let token = user?.accessToken.tokenString {
                        continuation.resume(returning: token)
                    } else {
                        continuation.resume(throwing: NSError(domain: "EmbeddingService", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed to get access token."]))
                    }
                }
            }
            return try await getVertexEmbedding(for: parts, projectID: project, location: loc, token: token)
            #endif
        } else if !key.isEmpty {
            return try await getDeveloperAPIEmbedding(for: parts, apiKey: key)
        } else {
            throw NSError(domain: "EmbeddingService", code: 2, userInfo: [NSLocalizedDescriptionKey: "No API credentials found."])
        }
    }
    
    private func getDeveloperAPIEmbedding(for parts: [ContentPart], apiKey: String) async throws -> [Float] {
        let modelName = "gemini-embedding-2-preview"
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(modelName):embedContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            throw NSError(domain: "EmbeddingService", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "model": "models/\(modelName)",
            "content": [
                "parts": parts.map { $0.dictionaryValue }
            ]
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await executeEmbeddingRequest(request)
    }
    
    private func getVertexEmbedding(for parts: [ContentPart], projectID: String, location: String, token: String) async throws -> [Float] {
        let modelName = "gemini-embedding-2-preview"
        let activeLocation = "us-central1" // Trying us-central1
        let host = "\(activeLocation)-aiplatform.googleapis.com"
        let urlString = "https://\(host)/v1/projects/\(projectID)/locations/\(activeLocation)/publishers/google/models/\(modelName):embedContent"
        
        guard let url = URL(string: urlString) else {
            throw NSError(domain: "EmbeddingService", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid Vertex AI URL"])
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let body: [String: Any] = [
            "content": [
                "parts": parts.map { $0.dictionaryValue }
            ]
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await executeEmbeddingRequest(request)
    }
    
    private func executeEmbeddingRequest(_ request: URLRequest) async throws -> [Float] {
        var delay = 2.0
        var retries = 6
        while retries > 0 {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    let result = try JSONDecoder().decode(EmbeddingResponse.self, from: data)
                    return result.embedding.values
                } else if httpResponse.statusCode == 429 || httpResponse.statusCode == 503 {
                    print("    ⚠️ API Rate limit/Overload (\(httpResponse.statusCode)). Retrying in \(delay) seconds...")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    delay *= 2
                    retries -= 1
                    continue
                } else {
                    let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
                    throw NSError(domain: "EmbeddingService", code: 1, userInfo: [NSLocalizedDescriptionKey: "API returned error (\(httpResponse.statusCode)): \(errorBody)"])
                }
            }
        }
        throw NSError(domain: "EmbeddingService", code: 3, userInfo: [NSLocalizedDescriptionKey: "Max retries reached for API limits."])
    }
}

struct EmbeddingResponse: Codable {
    let embedding: EmbeddingValues
}

struct EmbeddingValues: Codable {
    let values: [Float]
}
