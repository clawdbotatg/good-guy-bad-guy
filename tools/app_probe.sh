#!/bin/bash
# Headless app probe — the faithful "does it give weird/incomplete responses?" test.
#
# The iOS Simulator can't run Core ML on this Mac, so it can't show the real
# response to a photo. macOS CAN run Core ML natively, so this compiles the
# app's REAL Swift code (ClassifierEngine → PlantClassifier → DangerTable) with
# the REAL bundled model and prints the EXACT string the app would render on
# screen for each image — then checks it for the incomplete-output signatures
# that got the submission rejected (mid-sentence cutoff, missing verdict line,
# stray template markers).
#
#   tools/app_probe.sh <image.jpg> [more images...]
set -e
DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$DIR/GoodGuyBadGuy"
MODEL="${GGBG_MODEL_PATH:-$SRC/Resources/PoisonIvyBioCLIP.mlpackage}"
BUILD="$(mktemp -d)"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

cat > "$BUILD/main.swift" <<'SWIFT'
import Foundation
import CoreImage

// Minimal stand-in for the app's ChatMessage: DangerTable only references its
// nested Verdict enum, and the real ChatMessage.swift imports UIKit (not
// available in a macOS command-line build). The verdict text we assert on is
// composed as a plain string, so this changes nothing about the output.
enum ChatMessage { enum Verdict { case goodGuy, badGuy, caution } }

/// The exact classes of failure the App Review engineer saw: an answer that is
/// cut off mid-sentence, missing its verdict line, empty, or still carrying a
/// prompt-template placeholder. The old VLM could produce any of these; this
/// asserts the new build never does.
func wellFormedIssues(_ s: String) -> [String] {
    var issues: [String] = []
    if !s.contains("ID:") { issues.append("missing ID line") }
    let verdicts = ["VERDICT: GOOD GUY", "VERDICT: BAD GUY", "VERDICT: CAUTION"]
    if !verdicts.contains(where: s.contains) { issues.append("missing/garbled VERDICT line") }
    if s.contains("<") || s.contains(">") { issues.append("stray template marker") }
    if let r = s.range(of: "VERDICT:") {
        let note = s[r.upperBound...].split(separator: "\n").dropFirst()
            .joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if note.isEmpty { issues.append("empty note") }
        else if let last = note.last, !".!?\"".contains(last) {
            issues.append("note ends mid-sentence: …\(note.suffix(24))")
        }
    }
    return issues
}

@MainActor
func run() {
    let engine = ClassifierEngine()
    for path in CommandLine.arguments.dropFirst() {
        let name = URL(fileURLWithPath: path).lastPathComponent
        print("════════ \(name) ════════")
        guard let ci = CIImage(contentsOf: URL(fileURLWithPath: path)) else {
            print("⚠️  could not load image\n"); continue
        }
        let text = engine.identify(ci).text
        print(text)
        let issues = wellFormedIssues(text)
        print(issues.isEmpty
            ? "✅ well-formed response (no incomplete/weird output)"
            : "❌ PROBLEM: \(issues.joined(separator: "; "))")
        print("")
    }
}

MainActor.assumeIsolated { run() }
SWIFT

swiftc -O \
  "$SRC/DebugLog.swift" \
  "$SRC/LLM/DangerData.swift" \
  "$SRC/LLM/DangerTable.swift" \
  "$SRC/LLM/PlantClassifier.swift" \
  "$SRC/LLM/ClassifierEngine.swift" \
  "$BUILD/main.swift" \
  -o "$BUILD/probe"

GGBG_MODEL_PATH="$MODEL" "$BUILD/probe" "$@"
