import Foundation
#if !CLI
import GoogleSignIn
#endif

final class ImageGenerationService: @unchecked Sendable {
    private var projectID: String {
        UserDefaults.standard.string(forKey: "gcpProjectID") ?? "generative-bazaar-001"
    }
    
    private var location: String {
        UserDefaults.standard.string(forKey: "gcpLocation") ?? "us-central1"
    }
    
    init() {}
    
    struct ImageResult {
        let imageData: Data
        let mimeType: String
    }
    
    func generateImage(prompt: String, model: String = "gemini-3.1-flash-image-preview", authToken: String? = nil, projectID: String? = nil, location: String? = nil) async throws -> ImageResult {
        let activeProject = projectID ?? self.projectID
        let activeLocation = location ?? self.location
        
        // Gemini 3.1 (Nano Banana) uses :generateContent
        let host = activeLocation == "global" ? "aiplatform.googleapis.com" : "\(activeLocation)-aiplatform.googleapis.com"
        let urlString = "https://\(host)/v1beta1/projects/\(activeProject)/locations/\(activeLocation)/publishers/google/models/\(model):generateContent"
        
        guard let url = URL(string: urlString) else {
            throw NSError(domain: "ImageGenerationService", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
        }
        
        let token: String
        if let providedToken = authToken {
            token = providedToken
        } else {
            #if CLI
            throw NSError(domain: "ImageGenerationService", code: 4, userInfo: [NSLocalizedDescriptionKey: "Authentication required for CLI (provide authToken)."])
            #else
            guard let user = await MainActor.run(body: { GIDSignIn.sharedInstance.currentUser }) else {
                throw NSError(domain: "ImageGenerationService", code: 4, userInfo: [NSLocalizedDescriptionKey: "Authentication required."])
            }
            
            token = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                user.refreshTokensIfNeeded { user, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else if let token = user?.accessToken.tokenString {
                        continuation.resume(returning: token)
                    } else {
                        continuation.resume(throwing: NSError(domain: "ImageGenerationService", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed to get access token."]))
                    }
                }
            }
            #endif
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        // Gemini 3.1 Image Generation Payload
        let body: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": [
                        ["text": prompt]
                    ]
                ]
            ],
            "generationConfig": [
                "responseModalities": ["IMAGE"]
            ]
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "ImageGenerationService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Gemini Image API error: \(errorBody)"])
        }
        
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let candidates = json?["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let firstPart = parts.first else {
            print("❌ Invalid image response structure: \(String(data: data, encoding: .utf8) ?? "Unable to decode data")")
            throw NSError(domain: "ImageGenerationService", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid response format from Gemini Image API."])
        }
        
        let inlineData = (firstPart["inline_data"] as? [String: Any]) ?? (firstPart["inlineData"] as? [String: Any])
        guard let dataStr = inlineData?["data"] as? String,
              let imageData = Data(base64Encoded: dataStr) else {
            print("❌ Could not find inline data in part: \(firstPart)")
            throw NSError(domain: "ImageGenerationService", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid image data in response."])
        }
        
        let mimeType = (inlineData?["mime_type"] as? String) ?? (inlineData?["mimeType"] as? String) ?? "image/png"
        return ImageResult(imageData: imageData, mimeType: mimeType)
    }
}
