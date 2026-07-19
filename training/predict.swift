// Run the trained Core ML classifier on every held-out test image and record
// the top predicted label + confidence — exactly how the iPhone app will call it
// (Vision + Core ML). Writes predictions.csv for the threshold analysis.
//
//   swift predict.swift

import Foundation
import CoreML
import Vision
import AppKit

let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let modelURL = here.appendingPathComponent("PoisonIvyClassifier.mlmodel")
let testDir = here.appendingPathComponent("testset")

let compiled = try MLModel.compileModel(at: modelURL)
let mlmodel = try MLModel(contentsOf: compiled)
let vnModel = try VNCoreMLModel(for: mlmodel)

var lines = ["true,pred,confidence"]
var n = 0
let classes = (try FileManager.default.contentsOfDirectory(atPath: testDir.path)).sorted()
for cls in classes {
    let clsDir = testDir.appendingPathComponent(cls)
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: clsDir.path, isDirectory: &isDir), isDir.boolValue
    else { continue }
    let files = (try? FileManager.default.contentsOfDirectory(atPath: clsDir.path)) ?? []
    for f in files where f.hasSuffix(".jpg") {
        let imgURL = clsDir.appendingPathComponent(f)
        guard let img = NSImage(contentsOf: imgURL),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
        let request = VNCoreMLRequest(model: vnModel)
        request.imageCropAndScaleOption = .centerCrop
        try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
        if let top = (request.results as? [VNClassificationObservation])?.first {
            lines.append("\(cls),\(top.identifier),\(top.confidence)")
            n += 1
        }
    }
}
try lines.joined(separator: "\n").write(
    to: here.appendingPathComponent("predictions.csv"), atomically: true, encoding: .utf8)
print("Wrote predictions.csv (\(n) images)")
