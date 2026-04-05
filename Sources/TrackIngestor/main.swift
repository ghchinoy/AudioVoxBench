import Foundation

struct BenchConfig: Codable {
    let project_id: String
    let firestore_database: String?
    let firestore_collection: String?
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
    let type: String?
    let expected_matches: [String]?
}

print("📥 AudioVox Track Ingestor")

// 1. Load Config
let configURL = URL(fileURLWithPath: "config.json")
guard let configData = try? Data(contentsOf: configURL),
      let config = try? JSONDecoder().decode(BenchConfig.self, from: configData) else {
    print("❌ Error: Could not load config.json")
    exit(1)
}

let databaseId = config.firestore_database ?? "musicbox"
let collectionId = config.firestore_collection ?? "musicbox_history"

// 2. Parse Arguments
var emailFilter: String? = nil
var limit: Int = 50
var outputDbFile: String = "tests/production_db.json"
var outputProbesFile: String = "tests/production_probes.json"
var splitRatio: Double = 0.0

let args = CommandLine.arguments
for i in 0..<args.count {
    if args[i] == "--email" && i + 1 < args.count {
        emailFilter = args[i+1]
    } else if args[i] == "--limit" && i + 1 < args.count {
        limit = Int(args[i+1]) ?? 50
    } else if args[i] == "--output" && i + 1 < args.count {
        outputDbFile = args[i+1]
    } else if args[i] == "--output-db" && i + 1 < args.count {
        outputDbFile = args[i+1]
    } else if args[i] == "--output-probes" && i + 1 < args.count {
        outputProbesFile = args[i+1]
    } else if args[i] == "--split" && i + 1 < args.count {
        splitRatio = Double(args[i+1]) ?? 0.0
    }
}

guard let token = ProcessInfo.processInfo.environment["GCP_ACCESS_TOKEN"] else {
    print("❌ Error: GCP_ACCESS_TOKEN not set.")
    exit(1)
}

print("📍 Project: \(config.project_id)")
print("🗄️  Database: \(databaseId)")
print("📂 Collection: \(collectionId)")
if let email = emailFilter {
    print("👤 Filtering by email: \(email)")
} else {
    print("👑 Admin Mode: Fetching up to \(limit) tracks")
}
if splitRatio > 0 {
    print("✂️  Corpus Split: \(Int(splitRatio * 100))% will be held out as probes")
}

// 3. Construct Firestore Query
let urlString = "https://firestore.googleapis.com/v1/projects/\(config.project_id)/databases/\(databaseId)/documents:runQuery"
guard let url = URL(string: urlString) else { exit(1) }

var request = URLRequest(url: url)
request.httpMethod = "POST"
request.addValue("application/json", forHTTPHeaderField: "Content-Type")
request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

var query: [String: Any] = [
    "from": [["collectionId": collectionId]],
    "limit": limit
]

if let email = emailFilter {
    query["where"] = [
        "fieldFilter": [
            "field": ["fieldPath": "user_email"],
            "op": "EQUAL",
            "value": ["stringValue": email]
        ]
    ]
}

let body = ["structuredQuery": query]
request.httpBody = try? JSONSerialization.data(withJSONObject: body)

// 4. Execute and Transform
let semaphore = DispatchSemaphore(value: 0)
Task {
    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            let err = String(data: data, encoding: .utf8) ?? ""
            print("❌ Firestore API Error (\(httpResponse.statusCode)): \(err)")
            semaphore.signal()
            return
        }
        
        let rawResults = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        var dbTracks: [TrackBench] = []
        var probeTracks: [TrackBench] = []
        
        for result in rawResults {
            guard let doc = result["document"] as? [String: Any],
                  let fields = doc["fields"] as? [String: Any],
                  let name = doc["name"] as? String else { continue }
            
            let id = name.components(separatedBy: "/").last ?? UUID().uuidString
            
            func val(_ key: String) -> String? {
                let dict = fields[key] as? [String: Any]
                return dict?["stringValue"] as? String
            }
            
            func dVal(_ key: String) -> Double? {
                let dict = fields[key] as? [String: Any]
                if let s = dict?["stringValue"] as? String { return Double(s) }
                return dict?["doubleValue"] as? Double
            }
            
            // Map Firestore schema to TrackBench
            let track = TrackBench(
                id: id,
                title: val("title") ?? "Untitled",
                prompt: val("prompt") ?? "",
                caption: val("caption") ?? "",
                image_url: val("image_url"),
                audio_url: val("audio_url"),
                mosic: dVal("mosic"),
                ground_truth_queries: nil,
                type: nil,
                expected_matches: nil
            )
            
            // If splitting, randomly hold out tracks as probes
            if splitRatio > 0 && Double.random(in: 0..<1) < splitRatio {
                // Randomly assign as an audio or image probe for variety
                let probeType = Bool.random() ? "audio_probe" : "image_probe"
                
                let probeTrack = TrackBench(
                    id: id,
                    title: track.title,
                    prompt: track.prompt,
                    caption: track.caption,
                    image_url: track.image_url,
                    audio_url: track.audio_url,
                    mosic: track.mosic,
                    ground_truth_queries: nil,
                    type: probeType,
                    expected_matches: [id] // Self-Retrieval!
                )
                probeTracks.append(probeTrack)
            }
            
            // ALL tracks go into the database target set
            dbTracks.append(track)
        }
        
        print("✅ Successfully ingested \(dbTracks.count) total tracks for the database.")
        if splitRatio > 0 {
            print("   ↳ Designated \(probeTracks.count) as hold-out probes.")
        }
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        
        let dbURL = URL(fileURLWithPath: outputDbFile)
        try? FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(dbTracks).write(to: dbURL)
        print("💾 Saved Database to: \(outputDbFile)")
        
        if splitRatio > 0 {
            let probesURL = URL(fileURLWithPath: outputProbesFile)
            try encoder.encode(probeTracks).write(to: probesURL)
            print("💾 Saved Probes to: \(outputProbesFile)")
        }
        
    } catch {
        print("❌ Error during ingestion: \(error.localizedDescription)")
    }
    semaphore.signal()
}
semaphore.wait()
print("\n✅ Ingestion complete.")
