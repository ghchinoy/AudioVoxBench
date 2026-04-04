import Foundation

struct BenchConfig: Codable {
    let project_id: String
    let location: String
    let bucket_name: String
    let seed_data_path: String
    let golden_set_path: String
    let models: ModelConfig
    
    struct ModelConfig: Codable {
        let audio: String
        let image: String
    }
}

struct TrackSeed: Codable {
    let id: String
    let title: String
    let prompt: String
    let caption: String
}

print("🌱 AudioVox Track Seeder (df2.1)")

// 1. Load Config
let configURL = URL(fileURLWithPath: "config.json")
guard let configData = try? Data(contentsOf: configURL),
      let config = try? JSONDecoder().decode(BenchConfig.self, from: configData) else {
    print("❌ Error: Could not load config.json")
    exit(1)
}

print("📍 Project: \(config.project_id) (\(config.location))")
print("🪣  Bucket: \(config.bucket_name)")

guard let token = ProcessInfo.processInfo.environment["GCP_ACCESS_TOKEN"] else {
    print("❌ Error: GCP_ACCESS_TOKEN not set.")
    exit(1)
}

// 2. Load Data (accepts arg)
let inputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : config.golden_set_path
let fileURL = URL(fileURLWithPath: inputPath)
guard let data = try? Data(contentsOf: fileURL),
      let seeds = try? JSONDecoder().decode([TrackSeed].self, from: data) else {
    print("❌ Error: Could not load data at \(inputPath)")
    exit(1)
}

let genService = TrackGenerationService()
let imgService = ImageGenerationService()

print("Loaded \(seeds.count) items from \(inputPath). Starting generation...")

for seed in seeds {
    print("\n  [Seed] Generating '\(seed.title)'...")
    
    let semaphore = DispatchSemaphore(value: 0)
    
    Task {
        do {
            // A. Generate Audio
            let result = try await genService.generateAudio(
                prompt: seed.prompt, 
                model: config.models.audio,
                authToken: token,
                projectID: config.project_id,
                location: "global" // Lyria interactions is global
            )
            print("    ✅ Audio Success: Received \(result.audioData.count) bytes")
            
            let audioPath = "\(config.seed_data_path)/\(seed.id).mp3"
            try? FileManager.default.createDirectory(atPath: config.seed_data_path, withIntermediateDirectories: true)
            try result.audioData.write(to: URL(fileURLWithPath: audioPath))
            
            // B. Generate Image
            let imgResult = try await imgService.generateImage(
                prompt: seed.caption, 
                model: config.models.image,
                authToken: token,
                projectID: config.project_id,
                location: "global" // Preview models are global
            )
            print("    ✅ Image Success: Received \(imgResult.imageData.count) bytes")
            
            let imagePath = "\(config.seed_data_path)/\(seed.id).jpg"
            try imgResult.imageData.write(to: URL(fileURLWithPath: imagePath))

            // C. GCS UPLOAD
            func upload(filePath: String, destination: String, contentType: String) {
                let cmd = "curl -s -X POST --data-binary @\(filePath) -H \"Authorization: Bearer \(token)\" -H \"Content-Type: \(contentType)\" \"https://storage.googleapis.com/upload/storage/v1/b/\(config.bucket_name)/o?uploadType=media&name=\(destination)\""
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["bash", "-c", cmd]
                try? process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    print("    ☁️  Uploaded to \(destination)")
                } else {
                    print("    ❌ Upload failed for \(filePath)")
                }
            }

            upload(filePath: audioPath, destination: "bench/audio/\(seed.id).mp3", contentType: "audio/mpeg")
            upload(filePath: imagePath, destination: "bench/images/\(seed.id).jpg", contentType: "image/jpeg")
            
        } catch {
            print("    ❌ Failed: \(error.localizedDescription)")
        }
        semaphore.signal()
    }
    semaphore.wait()
}

print("\n✅ Seeding run complete.")
