// Train TreadWear and InteriorCondition image classifiers with Create ML (on a Mac):
//   swift TrainImageClassifiers.swift tread     /path/to/tread_images     ./TreadWear.mlmodel
//   swift TrainImageClassifiers.swift interior  /path/to/interior_images  ./InteriorCondition.mlmodel
//
// tread_images/   good/ fair/ worn/ uneven/
// interior_images/ clean/ seat_tear/ stain/ worn_steering/ worn_pedals/ dash_warning/ headliner_sag/
// ~200+ images per class, varied lighting/cars. Class names must match the app.
import CreateML
import Foundation

let a = CommandLine.arguments
guard a.count == 4 else { print("usage: kind dataDir out.mlmodel"); exit(1) }
var params = MLImageClassifier.ModelParameters()
params.featureExtractor = .scenePrint(revision: 2)
params.augmentationOptions = [.crop, .exposure, .blur, .rotation]
params.maxIterations = 60
let clf = try MLImageClassifier(trainingData: .labeledDirectories(at: URL(fileURLWithPath: a[2])), parameters: params)
print("Validation accuracy:", 1 - clf.validationMetrics.classificationError)
try clf.write(to: URL(fileURLWithPath: a[3]))
