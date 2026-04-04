# AudioVoxBench: Multimodal Embedding Benchmark

`AudioVoxBench` is a standalone Swift command-line suite designed to evaluate semantic search relevance using the **Gemini Embedding 2** model. It allows developers to compare different indexing strategies (text-only vs. interleaved multimodal) to determine the highest possible search recall.

## Goals
- **Objective Measurement**: Calculate Mean Reciprocal Rank (MRR) for various "ensemble" embedding strategies.
- **Data-Driven Roadmap**: Identify if adding raw audio and image data to embeddings actually improves user search experience compared to rich text metadata.
- **Reproducibility**: Provide a consistent "Golden Set" of tracks and queries to track semantic search improvements over time.

## Components
1. **`TrackSeeder`**: A tool to generate audio (via Lyria 3) and images (via **Gemini 3.1 Flash Image / Nano Banana 2**) for a set of prompts defined in `golden_set.json`, and upload them to Google Cloud Storage.
2. **`AudioVoxBench`**: The main evaluation tool. It iterates through strategies, indexes the "Golden Set" into a local vector database (sqlite-vec), and runs ground-truth queries to score recall.

## Prerequisites
To run this suite independently, you need:
- **Google Cloud Project**: With the Vertex AI API enabled.
- **Permissions**: Your account (or service account) needs `aiplatform.user` and `storage.objectAdmin`.
- **Lyria API Access**: Specifically the `interactions` endpoint for audio generation.
- **GCS Bucket**: A bucket to host the multimodal assets (audio/mp3 and images/jpg).
- **Environment**: 
  - `GCP_ACCESS_TOKEN`: A valid OAuth2 token (run `gcloud auth print-access-token`).
  - Swift 5.9+ / macOS 14+.

## Quick Start
1. **Initial Setup**:
   ```bash
   cp config.json.sample config.json
   mkdir -p tests
   cp golden_set.json.sample tests/golden_set.json
   ```
2. **Prepare Data**: Edit `config.json` with your GCP Project details and `tests/golden_set.json` with your desired prompts.
3. **Seed Assets**: 
   ```bash
   cd standalone/AudioVoxBench
   export GCP_ACCESS_TOKEN=$(gcloud auth print-access-token)
   swift run TrackSeeder
   ```
4. **Run Benchmark**:
   ```bash
   swift run AudioVoxBench
   ```

## Results & Reports
Benchmark results are stored in `docs/benchmarks/run_[date].md`.
Current "Winner": **Strategy C (Semantic Text-Augmentation)**.

## Pricing Estimates (3-Track Run)
Running this benchmark with the default 3-track "Golden Set" costs approximately **$1.28 USD** on Vertex AI.

| Component | Quantity | Est. Unit Cost | Subtotal |
| :--- | :--- | :--- | :--- |
| **Audio** (Lyria 3) | 3 clips (30s ea) | $0.36 / clip | **$1.08** |
| **Images** (Gemini 3.1 Flash) | 3 images (1K) | $0.067 / image | **$0.20** |
| **Embeddings** (Gemini 2) | 100+ calls | $0.025 / 1M tokens | **<$0.01** |
| **TOTAL** | | | **~$1.28** |

*Note: Strategy C (Text-only) is the most cost-effective as it bypasses raw image/audio generation costs for subsequent searches.*
