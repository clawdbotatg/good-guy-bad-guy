import CoreImage
import CoreML
import Foundation
import Vision

/// On-device Core ML classifier for poison ivy / oak / sumac and their common
/// harmless look-alikes. Trained with Create ML transfer learning on ~12k
/// CC-licensed iNaturalist photos; ships as a ~70 KB model and runs fully
/// offline via Vision — on both device and the simulator (unlike MLX).
///
/// **It only NAMES the plant; it never decides danger.** The name feeds
/// `DangerTable`, same as the VLM's. It is a closed set over 12 plant classes,
/// so a low top-confidence (or a non-plant photo) is routed back to the VLM by
/// `MLXEngine.identify` — this classifier is the fast, accurate first look for
/// the plants people actually get hurt by.
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
        guard
            let url = Bundle.main.url(
                forResource: "PoisonIvyClassifier", withExtension: "mlmodelc"),
            let ml = try? MLModel(contentsOf: url),
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

/// How the classifier's prediction routes into a verdict. Thresholds come from
/// the held-out measurement (training/analyze_threshold.py): at a 0.90 gate the
/// dangerous-called-safe rate is ~0.4%, at 0.95 it's ~0%. Safety-first:
/// - dangerous class, conf ≥ MIN            -> use it (BAD GUY / CAUTION)
/// - harmless class, conf ≥ CONFIDENT       -> use it (GOOD GUY)
/// - harmless class, MIN ≤ conf < CONFIDENT -> use it but HEDGED (-> CAUTION)
/// - anything below MIN                      -> defer to the VLM
enum PlantRoute {
    static let confident = 0.90
    static let minimum = 0.55

    /// (use the classifier?, treat as hedged?)
    static func decide(_ p: PlantClassifier.Prediction) -> (use: Bool, hedged: Bool) {
        if p.isDangerous {
            return (p.confidence >= minimum, false)
        }
        if p.confidence >= confident { return (true, false) }
        if p.confidence >= minimum { return (true, true) }
        return (false, false)
    }
}
