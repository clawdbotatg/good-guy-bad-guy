import CoreImage
import Foundation

/// The app's whole brain, now that identification is a bundled Core ML
/// classifier (`PlantClassifier`) instead of a downloaded VLM.
///
/// **No download, no cloud, no text generation.** It runs the instant the app
/// opens, fully offline, and produces a clean `ID:` line plus the
/// `DangerTable` verdict — the model can no longer "leave incomplete output",
/// because it doesn't write prose at all. Core ML needs no GPU, so this runs
/// identically on device and in the simulator (the simulator is a full
/// end-to-end test of the real path).
///
/// The model still never decides danger: it names the plant, and `DangerTable`
/// (curated Swift data) decides the verdict.
@MainActor
final class ClassifierEngine {

    struct Answer {
        let idLine: String       // e.g. "ID: Poison ivy"
        let verdictText: String  // e.g. "VERDICT: BAD GUY\n\n…"
        /// Combined message body in the format `ChatMessage` parses.
        var text: String { idLine + "\n" + verdictText }
    }

    private let classifier = PlantClassifier()

    /// Identify a photo and compose the verdict. Never throws — a missing model
    /// or an unrecognised photo both resolve to an honest CAUTION.
    ///
    /// Safety-first routing (thresholds in `PlantRoute`):
    /// - dangerous class, conf ≥ dangerFlag → BAD GUY (the table's rash warning)
    /// - dangerous class, below that        → CAUTION that still NAMES it
    /// - harmless class, conf ≥ goodConfident → GOOD GUY
    /// - harmless class, ≥ harmlessCaution    → hedged CAUTION (not sure enough)
    /// - anything weaker                       → honest "not sure" CAUTION
    func identify(_ image: CIImage) -> Answer {
        guard let classifier, let p = classifier.classify(image) else {
            return unknown(idLine: "ID: Couldn't identify it")
        }
        DebugLog.log("classifier: \(p.commonName) conf=\(p.confidence) bad=\(p.isDangerous)")
        let display = p.commonName.prefix(1).uppercased() + p.commonName.dropFirst()

        if p.isDangerous {
            if p.confidence >= PlantRoute.dangerFlag {
                // Table entry for poison ivy/oak/sumac → BAD GUY.
                let result = DangerTable.verdict(name: p.commonName, category: "plant")
                return Answer(idLine: "ID: \(display)", verdictText: result.text)
            }
            // Low confidence, but the top guess is a rash-causer — warn and name it.
            return Answer(
                idLine: "ID: Possibly \(p.commonName)",
                verdictText:
                    "VERDICT: CAUTION\n\nThis could be \(p.commonName), which causes a rash — but I'm not certain. Treat it as dangerous: don't touch it, and never burn it. When in doubt, stay away.")
        }

        // Harmless class.
        if p.confidence >= PlantRoute.goodConfident {
            let result = DangerTable.verdict(name: p.commonName, category: "plant")
            return Answer(idLine: "ID: \(display)", verdictText: result.text)
        }
        if p.confidence >= PlantRoute.harmlessCaution {
            let result = DangerTable.verdict(name: p.commonName, category: "plant", hedged: true)
            return Answer(idLine: "ID: \(display)", verdictText: result.text)
        }
        return unknown(idLine: "ID: Not sure — treat with caution")
    }

    private func unknown(idLine: String) -> Answer {
        // name: nil → DangerTable's "I couldn't identify it" CAUTION note.
        Answer(idLine: idLine, verdictText: DangerTable.verdict(name: nil, category: "plant").text)
    }
}
