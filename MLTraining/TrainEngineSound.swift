// Train the ENGINE SOUND classifier with Create ML (run on a Mac):
//   swift TrainEngineSound.swift /path/to/engine_sounds  ./EngineSound.mlmodel
//
// Folder layout — one sub-folder per label, 3–10 s WAV/M4A clips (16-bit, mono, 44.1 kHz):
//   engine_sounds/healthy/ knock/ misfire/ belt_squeal/ tappet/ exhaust_leak/ background/
// Labels must match what EngineSoundAnalyzer reads: knock, misfire, belt_squeal, tappet, exhaust_leak.
//
// Data sources: record your own (best — same phones as your users) at workshops; public:
// "Car engine sound" and "Engine fault diagnosis" sets on Kaggle, and YouTube mechanics'
// clips (check licences). Aim for ≥ 150 clips per class, many different car models.
// Always include a "background" class (talking, traffic, wind) so noise isn't called a fault.
import CreateML
import Foundation

let args = CommandLine.arguments
let dataDir = URL(fileURLWithPath: args.count > 1 ? args[1] : "engine_sounds")
let outURL = URL(fileURLWithPath: args.count > 2 ? args[2] : "EngineSound.mlmodel")

var params = MLSoundClassifier.ModelParameters()
params.validation = .split(strategy: .automatic)
params.maxIterations = 100
params.overlapFactor = 0.5
params.featureExtractor = .audioFeaturePrint   // Apple's pretrained audio embedding (on-device, fast)

let model = try MLSoundClassifier(trainingData: .labeledDirectories(at: dataDir), parameters: params)
print("Training accuracy:", 1 - model.trainingMetrics.classificationError)
print("Validation accuracy:", 1 - model.validationMetrics.classificationError)
try model.write(to: outURL, metadata: MLModelMetadata(author: "Carlyze", shortDescription: "Engine fault sound classifier", version: "1.0"))
print("Saved", outURL.path)
