# Multimodal Ground Truth: Building AudioVoxBench
*By G. H. Chinoy*

## Why this matters
Semantic search is easy to demo but hard to deploy. I'm building a multimodal music application, Musicbox, that lives at the intersection of AI-generated tracks (with Lyria 3) and cinematic visuals (Gemini Image, aka Nano Banana), so the big question for this type of application isn't how do we search but instead, "What are we indexing?"

Conventional wisdom suggests that more data is better. If you have the audio and the artwork, and a state-of-the art multimodal embedding model, like Gemini Embedding 2, you should embed them all, right? I built **AudioVoxBench**, a standalone multimodal validation suite, to see just whether and when this makes the most sense and reveals a more nuanced truth about how Gemini Embedding 2 handles these interleaved modalities.

## The Strategy: Benchmarking the "Ensemble"
I built **AudioVoxBench** to evaluate five distinct indexing strategies, progressing from simple text to full multimodal interleaving:

*   **Strategy A (Baseline)**: Just the original generation prompt.
*   **Strategy B (Augmented)**: Prompt + a rich AI-generated visual caption.
*   **Strategy C (Semantic)**: Prompt + Caption + Technical "MOSIC" quality score (as text).
*   **Strategy D (Multimodal)**: Prompt + raw track image data.
*   **Strategy E (Full-Spectrum)**: The "Kitchen Sink"—Prompt, Caption, raw Image, and raw Audio.

Our evaluation metric is **Mean Reciprocal Rank (MRR)**. Unlike broader metrics like Precision@K, which measure how many relevant items are in a top list, MRR specifically rewards the "bullseye." It calculates the average of the reciprocal of the rank at which the correct ground-truth track was found. If the target is at #1, you get a 1.0; if it's at #2, you get a 0.5. For a discovery app where the "top hit" is what matters most to the user, MRR is the ultimate test of semantic precision.

We created a "Golden Set" of diverse tracks (Jazz, Metal, Ambient, etc.) and tested them against cross-modal probes. What happens when a user searches for a "stormy mountain vibe" using only an image?

## The Implementation
To keep our iteration cycle fast, we decoupled the benchmark from the main macOS app. We implemented a native Swift CLI suite that handles everything from asset generation via Lyria 3 to vector indexing using `sqlite-vec`.

Here’s a snippet of our `EmbeddingStrategy` logic, allowing us to swap indexing schemes at call-time:

```swift
enum EmbeddingStrategy: String, CaseIterable {
    case semantic = "C (Semantic)"
    case fullSpectrum = "E (Full-Spectrum)"
    
    func parts(track: TrackRecord) -> [ContentPart] {
        switch self {
        case .semantic:
            // Text-only augmentation
            return [.text("Prompt: \(track.prompt). Visual: \(track.caption). Quality: \(track.mosic)")]
        case .fullSpectrum:
            // Interleaved multimodal parts
            return [
                .text(track.prompt),
                .file(uri: track.imageUri, mimeType: "image/jpeg"),
                .file(uri: track.audioUri, mimeType: "audio/mpeg")
            ]
        }
    }
}
```

## The "Hard Part": Semantic Noise
The most surprising finding? **Text-Augmentation (Strategy C) outperformed Full-Spectrum interleaving.** 

Even when the search query was a purely acoustic probe (like a humming tune), the strategy that indexed the tracks as rich, descriptive text achieved a perfect **1.0 MRR**. The raw media in Strategy E, while powerful, introduced subtle "jitter"—semantic noise that actually displaced the concept center compared to well-crafted text descriptors.

## Key Takeaways
1. **The Text Anchor is King**: Gemini Embedding 2 has an incredible cross-modal alignment. Descriptive text remains the most stable "anchor" for semantic search, even for non-text queries.
2. **Visual Relevance Matters**: Replacing generic placeholders with semantically accurate images (generated via Nano Banana) boosted multimodal recall from 0.90 to 0.95.
3. **Economics vs. Performance**: Strategy C is virtually free (<$0.01 for 100+ calls), whereas Full-Spectrum indexing costs ~$0.43 per track in generation. 

For AudioVox, the path is clear: we are doubling down on high-fidelity captions and technical metadata. The result is a search experience that feels like magic, without the overhead of heavy media processing.

---
*AudioVoxBench is open source and available at [ghchinoy/AudioVoxBench](https://github.com/ghchinoy/AudioVoxBench).*
