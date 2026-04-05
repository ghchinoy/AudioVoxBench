# AudioVoxBench: Production Benchmarking Guide

While `AudioVoxBench` comes with a "Golden Set" of synthetic prompts (`tests/golden_set.json`) to quickly validate embeddings, its true power lies in analyzing your **live production data**. 

This guide details how to benchmark against a large, existing Firestore corpus (e.g., 600+ tracks) with zero manual labeling, using a technique called **Self-Retrieval Evaluation**.

## 1. The Challenge of Production Data
When evaluating a massive, unlabeled dataset, you lack "ground truth" search queries (i.e., you don't know exactly what text a user *would* type to find a specific track). Furthermore, generating new queries or evaluating results manually does not scale.

To solve this, we use the **80/20 Corpus Split** methodology.

## 2. The "Self-Retrieval" Methodology
Instead of inventing synthetic text queries, we use the tracks' own media (Audio and Images) as the search probes.

1. **The Target Set (80%)**: The vast majority of your tracks are indexed into the local `sqlite-vec` database using the five embedding strategies (A-E).
2. **The Probe Set (20%)**: A random 20% of your tracks are held out. We take their raw `.mp3`/`.wav` files or `.jpg`/`.png` covers and use them as the *search query*.
3. **The Metric**: We measure if the system can find the *exact same track* in the Target Set using only its media. 

If Strategy C (Text-only indexing) can successfully retrieve Track X when provided with the raw audio of Track X, it proves that the model's cross-modal semantic space is highly unified and robust.

## 3. Workflow: Ingestion & Splitting

The `TrackIngestor` tool has been enhanced to automatically perform this split for you directly from Firestore.

### Configuration
Ensure your `config.json` points to your production bucket and database:
```json
{
  "project_id": "generative-bazaar-001",
  "firestore_database": "musicbox",
  "firestore_collection": "musicbox_history",
  ...
}
```

### Ingestion Execution
Run the ingestor with the `--split` flag. For a 600-track database, a `0.2` split will index ~480 tracks and hold out ~120 as probes.

```bash
export GCP_ACCESS_TOKEN=$(gcloud auth print-access-token)

# Fetch 600 tracks, split 20% into probes
swift run TrackIngestor --limit 600 --split 0.2
```

This automatically generates two files:
- `tests/production_db.json` (The Target Set)
- `tests/production_probes.json` (The Probe Set, pre-configured for Self-Retrieval)

## 4. Workflow: Evaluation

Once the split is generated, run the benchmark suite against these new files:

```bash
swift run AudioVoxBench tests/production_db.json tests/production_probes.json
```

The benchmark will iterate through Strategies A-E and calculate the Mean Reciprocal Rank (MRR). A high MRR on Strategy C confirms that text-augmentation is sufficient for your current catalog density. 

## 5. Important: API Limits & Large Audio
When benchmarking against real production data, you may encounter `INVALID_ARGUMENT` errors from the Gemini Embedding 2 API during Strategy E (Full-Spectrum).

**The Cause**: The Gemini Embedding 2 API currently has strict, undocumented payload limits for raw media. While it handles images flawlessly, it will reject raw audio files that are too large (pragmatically, anything over ~2MB to 3.5MB, or roughly >1 minute of high-fidelity WAV audio). 

**The Solution**: 
- **Graceful Degradation**: `AudioVoxBench` is designed to gracefully catch and report these API errors. If a track is too large, it will print a warning and skip that specific track for Strategy E, while still completing the benchmark for all other valid tracks and strategies.
- **Future Optimization**: If Strategy E becomes the dominant production approach, you should segment or compress your audio files (e.g., passing only the first 30 seconds as a lower-bitrate MP3) before requesting the embedding. For semantic "vibe" checking, the first 15-30 seconds provides ample acoustic entropy.

## 6. Interpreting Results (Troubleshooting 0.0000 MRR)
If you run a benchmark on your production data and receive an MRR of `0.0000` across all strategies, it typically indicates a **Mismatch between Database and Probes**, rather than a model failure.

### The "Zero MRR" Phenomenon
When AudioVoxBench evaluates search precision, it scores results against a list of `expected_matches` defined in the probe JSON. 
If you mistakenly query your production database (which uses real UUIDs like `008c1346...`) using the synthetic sample probes (which expect IDs like `metal_01`), the benchmark will correctly execute the semantic search, but mathematically fail to find the expected ID in the top 10 results.

**Symptom**: The benchmark logs `❓ Probe top 3 matches` (indicating it found semantic matches) but scores a `0.0000` MRR.
**Solution**: Always use the automated 80/20 Corpus Split via `TrackIngestor`. This ensures the hold-out probes are mathematically mapped to the exact UUIDs of their corresponding tracks in the database.

### API Invalid Argument Errors
If Strategy D or E fails with an `INVALID_ARGUMENT` error, check the file type and size of the media in your GCS bucket:
- **MIME Types**: Gemini requires the exact MIME type (e.g., `audio/wav` for `.wav`, `audio/mpeg` for `.mp3`). AudioVoxBench handles standard extensions dynamically.
- **File Size**: As noted in Section 5, Gemini Embedding 2 will forcefully reject raw audio files that exceed undocumented limits (generally > 3.5MB).

## 7. Case Study: The Confidence Gap (Production Run)
When you run the benchmark against a real production library, you may notice that Strategy C and Strategy D behave differently than they do on synthetic "Golden Sets."

In a recent test against a live 60-track Firestore database, searching for a "Stormy Mountain" vibe using an **image probe** yielded the following top match for both strategies:

*   **Strategy C (Text-only)** matched the correct track with a mathematical distance of **1.1308**.
*   **Strategy D (Multimodal)** matched the exact same track but with a much higher confidence distance of **0.8831**.

**What this means:**
As your library grows (increasing semantic density), text descriptions begin to overlap. If you have 50 tracks described as "Lo-Fi Beats," Strategy C will struggle to rank them accurately. This is the **Saturation Point**. 
Strategy D and E mitigate this. By interleaving raw image or audio data, the embedding model gains the necessary visual or acoustic "entropy" to confidently distinguish between tracks that share identical text metadata. 
