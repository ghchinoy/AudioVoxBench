import Foundation
import GRDB
import SQLite3

struct BenchConfig: Codable {
    let project_id: String
    let location: String
    let bucket_name: String
    let seed_data_path: String
    let golden_set_path: String
    let models: ModelConfig
    
    struct ModelConfig: Codable {
        let embedding: String
    }
}

// Mock GIDSignIn for CLI (to allow linking EmbeddingService)
class GIDSignIn {
    static let sharedInstance = GIDSignIn()
    var currentUser: GIDUser? = nil
}
class GIDUser {
    struct AccessToken { var tokenString: String }
    var accessToken = AccessToken(tokenString: "")
    func refreshTokensIfNeeded(completion: (GIDUser?, Error?) -> Void) {}
}

struct TrackBench: Codable {
    let id: String
    let title: String
    let prompt: String
    let caption: String
    let image_url: String?
    let audio_url: String?
    let mosic: Double?
    let ground_truth_queries: [String]?
    
    // Phase 2 Probe Fields
    let type: String?
    let expected_matches: [String]?
}

enum EmbeddingStrategy: String, CaseIterable {
    case promptOnly = "A (Baseline)"
    case promptAndCaption = "B (Augmented)"
    case semantic = "C (Semantic)"
    case multimodalImage = "D (Multimodal)"
    case fullSpectrum = "E (Full-Spectrum)"
    
    func parts(track: TrackBench, config: BenchConfig) -> [EmbeddingService.ContentPart] {
        switch self {
        case .promptOnly:
            return [.text(track.prompt)]
        case .promptAndCaption:
            return [.text("Prompt: \(track.prompt). Visual: \(track.caption)")]
        case .semantic:
            let quality = (track.mosic ?? 4.5) > 4.5 ? "Pristine, high-fidelity audio." : "Standard audio."
            return [.text("Prompt: \(track.prompt). Visual: \(track.caption). Quality: \(quality)")]
        case .multimodalImage:
            let imageUri = "gs://\(config.bucket_name)/bench/images/\(track.id).jpg"
            return [
                .text(track.prompt),
                .file(uri: imageUri, mimeType: "image/jpeg")
            ]
        case .fullSpectrum:
            let imageUri = "gs://\(config.bucket_name)/bench/images/\(track.id).jpg"
            let audioUri = "gs://\(config.bucket_name)/bench/audio/\(track.id).mp3"
            return [
                .text("Prompt: \(track.prompt). Caption: \(track.caption)"),
                .file(uri: imageUri, mimeType: "image/jpeg"),
                .file(uri: audioUri, mimeType: "audio/mpeg")
            ]
        }
    }
}

// --- START ---
print("🚀 AudioVox Cross-Modal Discovery Evaluation (Phase 2)")

// 1. Load Config
let configURL = URL(fileURLWithPath: "config.json")
guard let configData = try? Data(contentsOf: configURL),
      let config = try? JSONDecoder().decode(BenchConfig.self, from: configData) else {
    print("❌ Error: Could not load config.json")
    exit(1)
}

guard let token = ProcessInfo.processInfo.environment["GCP_ACCESS_TOKEN"] else {
    print("❌ Error: GCP_ACCESS_TOKEN not set.")
    exit(1)
}

// 2. Load Database Tracks
let dbURL = URL(fileURLWithPath: "tests/golden_set_phase2.json")
guard let dbData = try? Data(contentsOf: dbURL),
      let tracks = try? JSONDecoder().decode([TrackBench].self, from: dbData) else {
    print("❌ Error: Could not load golden_set_phase2.json")
    exit(1)
}

// 3. Load Probes
let probesURL = URL(fileURLWithPath: "tests/probes_phase2.json")
guard let probesData = try? Data(contentsOf: probesURL),
      let probes = try? JSONDecoder().decode([TrackBench].self, from: probesData) else {
    print("❌ Error: Could not load probes_phase2.json")
    exit(1)
}

print("Indexed Database: \(tracks.count) tracks")
print("Probes: \(probes.count) (2 Image, 3 Audio)")

let embedService = EmbeddingService()
var summaryResults: [String: Double] = [:]

for strategy in EmbeddingStrategy.allCases {
    print("\n--- Testing Strategy: \(strategy.rawValue) ---")
    
    let semaphore = DispatchSemaphore(value: 0)
    
    Task {
        do {
            let store = try VectorStore()
            try store.clearAll()
            
            print("  Indexing...")
            for track in tracks {
                let parts = strategy.parts(track: track, config: config)
                let vector = try await embedService.getEmbedding(for: parts, authToken: token, projectID: config.project_id, location: "global")
                try store.insertTrack(id: track.id, title: track.title, prompt: track.prompt, vector: vector)
            }
            
            print("  Running cross-modal probes...")
            var totalRR: Double = 0
            
            for probe in probes {
                var queryParts: [EmbeddingService.ContentPart] = []
                if probe.type == "image_probe" {
                    let uri = "gs://\(config.bucket_name)/bench/images/\(probe.id).jpg"
                    queryParts = [.file(uri: uri, mimeType: "image/jpeg")]
                } else if probe.type == "audio_probe" {
                    let uri = "gs://\(config.bucket_name)/bench/audio/\(probe.id).mp3"
                    queryParts = [.file(uri: uri, mimeType: "audio/mpeg")]
                }
                
                let queryVector = try await embedService.getEmbedding(for: queryParts, authToken: token, projectID: config.project_id, location: "us-central1")
                let results = try store.search(queryVector: queryVector, limit: 10)
                
                var bestRank: Int? = nil
                for (index, result) in results.enumerated() {
                    if probe.expected_matches?.contains(result.id) ?? false {
                        bestRank = index
                        break
                    }
                }
                
                if let rank = bestRank {
                    totalRR += 1.0 / Double(rank + 1)
                    print("    ✅ Probe [\(probe.id)] matched '\(results[rank].id)' at rank \(rank + 1)")
                } else {
                    print("    ❌ Probe [\(probe.id)] failed to find expected matches in top 10.")
                }
            }
            
            let mrr = totalRR / Double(probes.count)
            summaryResults[strategy.rawValue] = mrr
            print("  📈 Phase 2 MRR for \(strategy.rawValue): \(String(format: "%.4f", mrr))")
            
        } catch {
            print("  ❌ Error in strategy \(strategy.rawValue): \(error.localizedDescription)")
        }
        semaphore.signal()
    }
    semaphore.wait()
}

// --- REPORT ---
print("\n" + String(repeating: "=", count: 40))
print(" CROSS-MODAL DISCOVERY SUMMARY (MRR)")
print(String(repeating: "=", count: 40))
for strategy in EmbeddingStrategy.allCases {
    let score = summaryResults[strategy.rawValue] ?? 0
    print("\(strategy.rawValue.padding(toLength: 25, withPad: " ", startingAt: 0)): \(String(format: "%.4f", score))")
}

let dateFormatter = DateFormatter()
dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm"
let dateStr = dateFormatter.string(from: Date())
let reportPath = "docs/benchmarks/run_\(dateStr).md"

var report = """
# AudioVoxBench Phase 2 Report
*Run Date: \(dateStr)*

## Configuration
- **Project**: \(config.project_id)
- **Model**: \(config.models.embedding)
- **Dataset Size**: \(tracks.count) tracks
- **Probe Count**: \(probes.count)

## Results (Mean Reciprocal Rank)

| Strategy | MRR |
| :--- | :--- |
"""

for strategy in EmbeddingStrategy.allCases {
    let score = summaryResults[strategy.rawValue] ?? 0
    report += "\n| \(strategy.rawValue) | \(String(format: "%.4f", score)) |"
}

do {
    try FileManager.default.createDirectory(atPath: "docs/benchmarks", withIntermediateDirectories: true)
    try report.write(to: URL(fileURLWithPath: reportPath), atomically: true, encoding: .utf8)
    print("\n📄 Report saved to: \(reportPath)")
} catch {
    print("\n❌ Failed to save report: \(error.localizedDescription)")
}

print("\n✅ Phase 2 Evaluation complete.")
