// Train an on-device image classifier for poison-ivy vs. look-alikes, headless.
//
//   swift train_classifier.swift
//
// Reads dataset/<class>/*.jpg, trains via Create ML transfer learning, prints
// accuracy, and writes PoisonIvyClassifier.mlmodel — drop straight into the app.
//
// Runs entirely on your Mac (Apple Silicon GPU). No cloud, no GPU rental.
// The output .mlmodel runs fully on-device on iPhone via Core ML / Vision.

import CreateML
import Foundation

let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let dataDir = here.appendingPathComponent("dataset")
let outFile = here.appendingPathComponent("PoisonIvyClassifier.mlmodel")

guard FileManager.default.fileExists(atPath: dataDir.path) else {
    print("No dataset/ folder found. Run download.py first.")
    exit(1)
}

print("Loading images from \(dataDir.path) …")
let data = MLImageClassifier.DataSource.labeledDirectories(at: dataDir)

// Augmentation matters a lot for a few-hundred-per-class dataset: it teaches the
// model that a rotated / cropped / differently-lit leaf is the same plant.
let params = MLImageClassifier.ModelParameters(
    validation: .split(strategy: .automatic),
    maxIterations: 25,
    augmentation: [.crop, .rotation, .blur, .flip, .exposure]
)

print("Training (transfer learning on Apple's vision backbone) …")
let model = try MLImageClassifier(trainingData: data, parameters: params)

let trainAcc = (1.0 - model.trainingMetrics.classificationError) * 100
let valAcc = (1.0 - model.validationMetrics.classificationError) * 100
print(String(format: "Training accuracy:   %.1f%%", trainAcc))
print(String(format: "Validation accuracy: %.1f%%", valAcc))

// Export the confusion matrix so we can collapse it to the only distinction the
// app cares about: dangerous-called-safe (a real error) vs. within-group mixups
// (harmless — same verdict either way).
let confusion = model.validationMetrics.confusion
var lines = ["true,pred,count"]
for row in confusion.rows {
    let t = row["True Label"]?.stringValue ?? "?"
    let p = row["Predicted"]?.stringValue ?? "?"
    let c = row["Count"]?.intValue ?? 0
    lines.append("\(t),\(p),\(c)")
}
try lines.joined(separator: "\n").write(
    to: here.appendingPathComponent("confusion.csv"), atomically: true, encoding: .utf8)
print("Wrote confusion.csv")

let meta = MLModelMetadata(
    author: "Good Guy Bad Guy",
    shortDescription: "Identifies poison ivy / oak / sumac and common harmless look-alikes from a photo.",
    version: "1.0"
)
try model.write(to: outFile, metadata: meta)
print("Wrote \(outFile.lastPathComponent)")
print("Validation accuracy is the honest number — it's on images the model never trained on.")
