# AudioVoxBench: Multimodal Embedding Benchmark

`AudioVoxBench` is a standalone Swift command-line suite designed to evaluate semantic search relevance using the **Gemini Embedding 2** model. It allows developers to compare different indexing strategies (text-only vs. interleaved multimodal) to determine the highest possible search recall. For more background, see [Multimodal Ground Truth: Building AudioVoxBench](https://ghc.wtf/writing/multimodal-ground-truth-building-audiovoxbench/)

![Workflow](docs/benchmarking_workflow.png)

## Goals
- **Objective Measurement**: Calculate Mean Reciprocal Rank (MRR) for various "ensemble" embedding strategies.
- **Data-Driven Roadmap**: Identify if adding raw audio and image data to embeddings actually improves user search experience compared to rich text metadata.
- **Reproducibility**: Provide a consistent "Golden Set" of tracks and queries to track semantic search improvements over time.

## Components
1. **`TrackSeeder`**: A tool to generate audio (via Lyria 3) and images (via **Gemini 3.1 Flash Image / Nano Banana 2**) for a set of synthetic prompts defined in `golden_set.json`, and upload them to Google Cloud Storage.
2. **`TrackIngestor`**: A tool to import existing tracks from a Firestore collection (e.g., production history) into the benchmark format, featuring automated 80/20 Corpus Splitting for self-retrieval testing.
3. **`AudioVoxBench`**: The main evaluation tool. It iterates through strategies, indexes the "Target Set" into a local vector database (sqlite-vec), and runs cross-modal queries to score recall.

## Prerequisites
To run this suite independently, you need:
- **Google Cloud Project**: With the Vertex AI API enabled.
- **Permissions**: Your account (or service account) needs `aiplatform.user` and `storage.objectAdmin`.
- **Lyria API Access**: Specifically the `interactions` endpoint for audio generation.
- **GCS Bucket**: A bucket to host the multimodal assets (audio/mp3 and images/jpg).
- **Environment**: 
  - `GCP_ACCESS_TOKEN`: A valid OAuth2 token (run `gcloud auth print-access-token`).
  - Swift 5.9+ / macOS 14+.

## Quick Start (Synthetic Data)
The fastest way to validate the system is using the included synthetic "Golden Set".
1. **Initial Setup**:
   ```bash
   cp config.json.sample config.json
   mkdir -p tests
   cp golden_set.json.sample tests/golden_set.json
   ```
2. **Prepare Data**: Edit `config.json` with your GCP Project details.
3. **Seed Assets**: 
   ```bash
   export GCP_ACCESS_TOKEN=$(gcloud auth print-access-token)
   swift run TrackSeeder
   ```
4. **Run Benchmark**:
   ```bash
   swift run AudioVoxBench
   ```

## Production Data Benchmarking
For instructions on how to evaluate a large, existing Firestore corpus (e.g., 600+ tracks) using the **80/20 Corpus Split** and **Self-Retrieval Evaluation** methodology, please read the [**Production Benchmarking Guide**](docs/PRODUCTION_BENCHMARKING.md).

> **Pricing Note:** Running AudioVoxBench against *existing* production data is incredibly cost-effective because it skips all Lyria and Gemini Image generation. A 60-track benchmark costs **<$0.01 USD**, and a massive 600-track benchmark costs only **~$0.07 USD** (embedding costs only).

## Results & Reports
Benchmark results are automatically stored in `docs/benchmarks/run_[date].md`.

### Production Scale Findings (600 Tracks)
While synthetic tests on small catalogs show **Strategy C (Semantic Text-Augmentation)** as the winner, running AudioVoxBench on a real production corpus of 600 tracks reveals a critical "Saturation Point":

| Strategy | MRR (600 Tracks) |
| :--- | :--- |
| **A (Baseline)** | 0.2931 |
| **C (Semantic)** | 0.3336 |
| **D (Multimodal)** | **0.4887** (Winner) |
| **E (Full-Spectrum)** | 0.4125 |

At scale, text descriptions collide. **Strategy D (Text + Image)** provides the necessary visual entropy to distinguish nearly identical tracks, making it the definitive choice for growing catalogs. Strategy E (Audio) suffers from undocumented API payload limits (>3MB) and 500 errors, which degrades search quality unless the audio is truncated to <30 seconds.
## Pricing Estimates (15-Asset Synthetic Run)
Running the synthetic benchmark with 10 database tracks and 5 hold-out probes (13 audio clips, 12 images) costs approximately **$5.50 USD** on Vertex AI.

| Component | Quantity | Est. Unit Cost | Subtotal |
| :--- | :--- | :--- | :--- |
| **Audio** (Lyria 3) | 13 clips (30s ea) | $0.36 / clip | **$4.68** |
| **Images** (Gemini 3.1 Flash) | 12 images (1K) | $0.067 / image | **$0.80** |
| **Embeddings** (Gemini 2) | 200+ calls | $0.025 / 1M tokens | **<$0.01** |
| **TOTAL** | | | **~$5.49** |

*Note: Strategy C (Text-only) is the most cost-effective as it bypasses raw image/audio generation costs for subsequent searches. Running the benchmark against existing production data is nearly free, as it only incurs the <$0.01 embedding cost.*
