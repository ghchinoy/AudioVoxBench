import Foundation
import GRDB
import SQLite3

// Declare the C function for Swift
@_silgen_name("sqlite3_vec_init")
func sqlite3_vec_init(_ db: OpaquePointer?, _ pzErrMsg: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, _ pApi: UnsafeMutableRawPointer?) -> Int32

final class VectorStore: @unchecked Sendable {
    private let dbQueue: DatabaseQueue
    
    init() throws {
        // Use a local database in the current directory for the benchmark
        let dbPath = "benchmark_vectors.sqlite"
        self.dbQueue = try DatabaseQueue(path: dbPath)
        
        try setupSchema()
    }
    
    private func setupSchema() throws {
        try dbQueue.write { db in
            if let pointer = db.sqliteConnection {
                _ = sqlite3_vec_init(pointer, nil, nil)
            }

            try db.execute(sql: "DROP TABLE IF EXISTS tracks")
            try db.execute(sql: "DROP TABLE IF EXISTS vec_tracks")

            try db.create(table: "tracks") { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text)
                t.column("prompt", .text)
            }
            
            try db.execute(sql: """
                CREATE VIRTUAL TABLE vec_tracks USING vec0(
                    id TEXT PRIMARY KEY,
                    embedding FLOAT[3072]
                )
            """)
        }
    }
    
    func insertTrack(id: String, title: String, prompt: String, vector: [Float]) throws {
        try dbQueue.write { db in
            if let pointer = db.sqliteConnection {
                _ = sqlite3_vec_init(pointer, nil, nil)
            }

            try db.execute(sql: "INSERT OR REPLACE INTO tracks(id, title, prompt) VALUES (?, ?, ?)",
                           arguments: [id, title, prompt])
            
            let vectorJson = "[\(vector.map { String($0) }.joined(separator: ","))]"
            try db.execute(sql: "INSERT OR REPLACE INTO vec_tracks(id, embedding) VALUES (?, ?)",
                           arguments: [id, vectorJson])
        }
    }
    
    func search(queryVector: [Float], limit: Int = 10) throws -> [(id: String, distance: Float)] {
        try dbQueue.read { db in
            if let pointer = db.sqliteConnection {
                _ = sqlite3_vec_init(pointer, nil, nil)
            }

            let queryJson = "[\(queryVector.map { String($0) }.joined(separator: ","))]"
            
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, distance
                FROM vec_tracks
                WHERE embedding MATCH ? AND k = ?
                ORDER BY distance
                """, arguments: [queryJson, limit])
            
            return rows.compactMap { row in
                guard let id: String = row["id"], let distance: Float = row["distance"] else { return nil }
                return (id: id, distance: distance)
            }
        }
    }
    
    func clearAll() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM tracks")
            try db.execute(sql: "DELETE FROM vec_tracks")
        }
    }
}
