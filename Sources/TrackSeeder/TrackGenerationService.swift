import Foundation
#if !CLI
import GoogleSignIn
#endif

final class TrackGenerationService: @unchecked Sendable {
    private var projectID: String {
        // Fallback to plist if not in UserDefaults
        UserDefaults.standard.string(forKey: "gcpProjectID") ?? "generative-bazaar-001"
    }
    
    private var location: String {
        UserDefaults.standard.string(forKey: "gcpLocation") ?? "global"
    }
    
    init() {}
    
    struct GenerationResult {
        let audioData: Data
        let mimeType: String
    }
    
    func generateAudio(prompt: String, model: String = "lyria-3-clip-preview", authToken: String? = nil, projectID: String? = nil, location: String? = nil) async throws -> GenerationResult {
        let activeProject = projectID ?? self.projectID
        let activeLocation = location ?? self.location
        let host = activeLocation == "global" ? "aiplatform.googleapis.com" : "\(activeLocation)-aiplatform.googleapis.com"
        let urlString = "https://\(host)/v1beta1/projects/\(activeProject)/locations/\(activeLocation)/interactions"
        
        guard let url = URL(string: urlString) else {
            throw NSError(domain: "TrackGenerationService", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
        }
        
        let token: String
        if let providedToken = authToken {
            token = providedToken
        } else {
            #if CLI
            throw NSError(domain: "TrackGenerationService", code: 4, userInfo: [NSLocalizedDescriptionKey: "Authentication required for CLI (provide authToken)."])
            #else
            // 1. Get OAuth Token from GoogleSignIn
            guard let user = await MainActor.run(body: { GIDSignIn.sharedInstance.currentUser }) else {
                throw NSError(domain: "TrackGenerationService", code: 4, userInfo: [NSLocalizedDescriptionKey: "Authentication required."])
            }
            
            token = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                user.refreshTokensIfNeeded { user, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else if let token = user?.accessToken.tokenString {
                        continuation.resume(returning: token)
                    } else {
                        continuation.resume(throwing: NSError(domain: "TrackGenerationService", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed to get access token."]))
                    }
                }
            }
            #endif
        }
        
        // 2. Build Request
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let body: [String: Any] = [
            "model": model,
            "input": [
                ["type": "text", "text": prompt]
            ]
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        // 3. Execute
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "TrackGenerationService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Lyria API error: \(errorBody)"])
        }
        
        // 4. Parse Response (Expects outputs with base64 data)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let outputs = json?["outputs"] as? [[String: Any]],
              let audioOutput = outputs.first(where: { $0["type"] as? String == "audio" }),
              let b64Data = audioOutput["data"] as? String,
              let mimeType = audioOutput["mime_type"] as? String,
              let audioData = Data(base64Encoded: b64Data) else {
            print("❌ Invalid response structure: \(String(data: data, encoding: .utf8) ?? "Unable to decode data")")
            throw NSError(domain: "TrackGenerationService", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid response format from Lyria API."])
        }
        
        return GenerationResult(audioData: audioData, mimeType: mimeType)
    }
}
