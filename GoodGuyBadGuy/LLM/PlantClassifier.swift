import CoreImage
import CoreML
import Foundation
import Vision

/// On-device Core ML classifier for poison ivy / oak / sumac and their common
/// harmless look-alikes. It's BioCLIP (a vision model trained on the tree of
/// life) plus a linear head fit on ~10k CC-licensed iNaturalist photos, 6-bit
/// palettized to ~65 MB. Held-out: 87% exact, 95% of dangerous plants flagged,
/// 0% called safe — a big step up from the earlier ~70% Create ML model. Runs
/// fully offline via Vision.
///
/// **It only NAMES the plant; it never decides danger.** The name feeds
/// `DangerTable`. It is a closed set over 12 plant classes, so a low
/// top-confidence (or a non-plant photo) resolves to an honest CAUTION in
/// `ClassifierEngine.identify` rather than a confident wrong guess.
struct PlantClassifier {

    struct Prediction {
        let commonName: String   // a `DangerTable` alias, e.g. "poison ivy"
        let confidence: Double   // 0...1 for the top class
        let isDangerous: Bool    // true for the Toxicodendron (rash) classes
    }

    /// Create ML uses the training folder name as the class label. Map each to
    /// the `DangerTable` common name it should look up, and whether it's one of
    /// the dangerous (rash-causing) species.
    private static let labelMap: [String: (name: String, bad: Bool)] = [
        "poison_ivy_eastern":  ("poison ivy", true),
        "poison_ivy_western":  ("poison ivy", true),
        "poison_oak_pacific":  ("poison oak", true),
        "poison_oak_atlantic": ("poison oak", true),
        "poison_sumac":        ("poison sumac", true),
        "virginia_creeper":    ("virginia creeper", false),
        "box_elder":           ("box elder", false),
        "brambles":            ("bramble", false),
        "fragrant_sumac":      ("fragrant sumac", false),
        "staghorn_sumac":      ("staghorn sumac", false),
        "jack_in_the_pulpit":  ("jack-in-the-pulpit", false),
        "hog_peanut":          ("hog peanut", false),
    ]

    private let model: VNCoreMLModel

    /// Nil if the bundled model is missing/unreadable — callers then fall back
    /// to the VLM, so a broken model degrades gracefully instead of crashing.
    init?() {
        let config = MLModelConfiguration()
        #if targetEnvironment(simulator)
        // The simulator has no Neural Engine; letting Core ML try to use it
        // fails with "Failed to create espresso context". CPU-only works
        // everywhere and, for a ~70 KB classifier, is still instant.
        config.computeUnits = .cpuOnly
        #endif
        guard
            let url = Bundle.main.url(
                forResource: "PoisonIvyBioCLIP", withExtension: "mlmodelc"),
            let ml = try? MLModel(contentsOf: url, configuration: config),
            let vn = try? VNCoreMLModel(for: ml)
        else {
            DebugLog.log("PlantClassifier: model not found in bundle")
            return nil
        }
        model = vn
    }

    /// Top prediction for a photo, or nil if inference failed or the label
    /// isn't one we map (should not happen — the model only emits our labels).
    func classify(_ image: CIImage) -> Prediction? {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .centerCrop
        do {
            try VNImageRequestHandler(ciImage: image, options: [:]).perform([request])
        } catch {
            DebugLog.log("PlantClassifier perform error: \(error)")
            return nil
        }
        guard
            let top = (request.results as? [VNClassificationObservation])?.first,
            let mapped = Self.labelMap[top.identifier]
        else { return nil }
        return Prediction(
            commonName: mapped.name, confidence: Double(top.confidence),
            isDangerous: mapped.bad)
    }
}

/// Confidence thresholds that turn a prediction into a verdict, calibrated
/// against the held-out set for the BioCLIP model (training/analyze_threshold.py
/// + analyze_dangerous.py):
///
/// - Dangerous plants: median top-confidence is ~0.75, so a **0.40** bar flags
///   ~84% straight to BAD GUY; anything dangerous below that still warns
///   (CAUTION that names the suspected plant). Lowering this bar is purely
///   safety-positive — it only adds warnings.
/// - Harmless plants: GOOD GUY needs **0.75** — the held-out dangerous-called-
///   safe rate is already 0.0% at that gate, so a higher bar would only add
///   needless CAUTIONs. A middling 0.50–0.75 is hedged down to CAUTION; below
///   0.50 we don't claim to know it.
///
/// The routing itself lives in `ClassifierEngine.identify` (it needs to compose
/// custom CAUTION text); these are the shared numbers.
enum PlantRoute {
    static let goodConfident = 0.75   // harmless → GOOD GUY
    static let harmlessCaution = 0.50  // harmless in [this, goodConfident) → hedged CAUTION
    static let dangerFlag = 0.40       // dangerous ≥ this → BAD GUY; below → named CAUTION
}
