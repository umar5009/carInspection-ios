# Carlyze: AI Car Inspection (iOS · SwiftUI)

Scan a new or used car → get a scored inspection report: panel-by-panel paint and repair status, replaced glass, accident likelihood, tyre age and tread, engine sound analysis, OBD-II fault codes, suspension damping and interior wear, each rated out of 10. You can export and share the report as a PDF.

## 1. Run it

```bash
brew install xcodegen
cd Carlyze
xcodegen            # generates Carlyze.xcodeproj from project.yml
open Carlyze.xcodeproj
```
Set your Team in Signing, then run on a **real iPhone**. The camera, microphone, motion sensors and Bluetooth don't work in the Simulator. You need iOS 17+ and Xcode 15+.

The app runs without any ML models.
Two ways to inspect: **Quick guided inspection** (voice-guided photos, then a grade sheet, with a
"Verify" button to add gauge, OBD and checks) and **Full inspection** (step hub with the AR paint scan). OCR (VIN, glass stamps, tyre DOT, odometer), engine-sound DSP, the suspension test, OBD-II, the paint gauge and the checklist all work without them. Add the trained models (section 4) to switch on damage detection, panel detection with colour-mismatch analysis, tread and interior classifiers, and the ML engine-sound classifier.

## 2. How each check is verified

| Report item | How it's measured | Confidence |
|---|---|---|
| Dents, scratches, cracks, broken glass/lamps, flat tyre, rust | YOLO11 detector (Core ML, Neural Engine) on photos or video frames | High for visible damage |
| **Which panel to check for repaint** | AR walk-around: panels found by `CarPartsYOLO` (or a framing guide gated by Vision's car detector) → CIEDE2000 colour + texture vs **comparable** panels in the same frame (sides vs sides, never bonnet vs fender), glare removed, odd-one-out attribution, must persist over 3 frames **and** 2 viewing angles | Indicator only: shown as **C / "Check"** |
| **Repaint / filler confirmed** | Paint thickness gauge, aimed with the AR crosshair (Bluetooth, keyboard-mode gauge, or typed). Baseline = roof, else median of readings, capped at 140 µm so a fully re-sprayed car is still caught. > 1.6× baseline (min 180 µm) = repainted, > 3.5× (min 400 µm) = filler | Ground truth |
| **Panel replaced** (door/fender/hood) | Colour mismatch + even re-spray thickness on a bolt-on panel, plus checklist | Medium |
| **Windscreen / rear screen / windows replaced** | OCR of the glass stamp: brand and year vs the other glass and the model year | High (a strong accident clue) |
| Accident likelihood | Weighted evidence. **Camera-only colour differences are capped** so they can never exceed "minor" or produce grade R | Summary |
| Tyres | DOT code OCR gives age, plus tread classifier and depth entry | High |
| Engine | DSP on the recording, Create ML sound classifier, OBD-II codes, pending codes, fuel trims, **recently-cleared-codes check** (PIDs 01/30/31) and ECU odometer (PID A6, newer cars) | Good for screening |
| Suspension | Accelerometer bounce test gives damping ratio ζ for each corner | Good for worn shocks |
| Interior / odometer fraud | Wear classifier + odometer OCR (prefers the ODO line, skips trip meters) + ECU odometer comparison | Indicator |

Each score in the report is marked **verified** (backed by a measurement), **camera** or **inspector**.

### AR paint scan (Full inspection → "AR paint scan + gauge")
1. Start at the front of the car (or tap **This is the front**), then walk clockwise. ARKit tracks which side you face; it does not drift like the compass.
2. Boxes: mint = compared and matching, white = found but nothing comparable in view, amber = colour differs. A panel is flagged only after 3 frames from 2 angles ≥ 12° apart, then gets a floating AR label.
3. Aim the crosshair at a panel and measure with the gauge. The reading is saved to that panel and the AR label shows *Genuine / Repainted / Filler*. Plastic bumpers are refused (magnetic gauges can't read them).
4. One clear frame per side is kept as evidence for the report ("Evidence photos" with panel and damage outlines).

### Paint gauges
- **Keyboard (HID) gauges**: pair in iPhone Settings › Bluetooth. They type into the reading field, which stays focused after each save.
- **BLE gauges**: tap the antenna button on the scan screen, scan, pick the device. `PaintGaugeService` subscribes to all notifying characteristics and parses text readings (`125`, `125 um`, `4.9 mil`). Binary protocols are shown as hex under "Last data"; add a decoder in `PaintGaugeService.decodeBinary(_:)` for your model.

### VIN and chassis numbers
17-character VINs give a model year. JDM imports usually carry a frame number such as `NZE141-1234567`; it is recognised too, and the year you enter is used.

## 3. Can a camera tell if a car was in an accident and parts were changed?

**Partly. Here's what's realistic:**

- **Yes, reliably:** visible damage, and **replaced glass** (via the stamp). Tyre age. Mismatched panels when the colour difference is clear (poor-quality repairs).
- **Often:** good-quality repaints show up as small colour or texture differences under even daylight, especially in low "raking" shots along the side. That's why the scan asks for 12 angles.
- **Not from a photo alone:** a *professional* repaint can be invisible to a camera. Structural or chassis repairs are underneath the car. The fix is to add cheap ground-truth sensors, which the app already supports:
  - **Paint thickness gauge** (≈ $30–150). It turns "possibly repainted" into a confirmed "repainted" or "body filler". Consider bundling or recommending one, or support a Bluetooth gauge next.
  - **OBD-II BLE dongle** (≈ $20). Reads fault codes and flags the check-engine light.
- The report says this clearly (see the disclaimer) so users aren't misled. Being honest about limits builds trust and helps with App Store review under Guideline 1.1/2.3 accuracy claims.

## 4. Train the AI models (`MLTraining/`)

| Model file | Script | Data |
|---|---|---|
| `CarDamageYOLO` | `train_damage.py` | CarDD (dent, scratch, crack, glass shatter, lamp broken, tire flat) + your own photos incl. rust. **CarDD is non-commercial**: license it or label your own data for a paid app |
| `CarPartsYOLO` | `train_parts.py` | Ultralytics `carparts-seg` (auto-download) + your labels for fenders, quarter panels, roof. The public set has no fenders/quarters/roof, and some side-less labels (`front_door`, `back_door`, `front_light`, `back_light`) which the app resolves from the scanned side. **Flip augmentation is off** because it would swap left/right labels. **This model is what makes the AR scan find panels anywhere in the frame; without it the scan falls back to a framing guide.** |
| `EngineSound` | `TrainEngineSound.swift` (Create ML) | Clips per class: healthy, knock, misfire, belt_squeal, tappet, exhaust_leak, background |
| `TreadWear`, `InteriorCondition` | `TrainImageClassifiers.swift` | Folders per class |

Drag each exported `.mlpackage` / `.mlmodel` into the Xcode target using the exact names above. `BundledModel` finds them automatically.

**Best upgrade path:** collect every user scan (with consent) together with gauge readings and mechanic verdicts. That labelled data is your moat. Retrain monthly.

## 5. Project structure
```
Carlyze/
  App/            CarlyzeApp (+ animated splash)
  Models/         InspectionModels (report schema), InspectionSession (capture state)
  Services/ML/    VisionModels, PaintAnalyzer (CIEDE2000), TextScanner (VIN/glass/DOT/odometer), EngineSoundAnalyzer
  Services/ML/    + LivePaintScanner (PanelLocator: model or framing fallback)
  Services/Hardware/ SuspensionTester (CoreMotion), OBDService (BLE ELM327), PaintGaugeService (BLE / HID gauges)
  Services/Capture/  CameraController, VideoFrameExtractor, ARScanController (ARKit + SceneKit labels)
  Services/       InspectionAnalyzer (pipeline), ReportStore
  Scoring/        ScoringEngine (0–10 ratings, accident likelihood, verdict)
  Views/          Home, Inspection flow + capture screens, Report + PDF export, components
  Resources/      Info.plist, Assets (AppIcon, LaunchLogo, LaunchBackground)
MLTraining/       training scripts + icon generator
```

## 6. Launch screen & icon
- **Static launch** (`Info.plist → UILaunchScreen`): navy `LaunchBackground` with `LaunchLogo`. It shows instantly with no storyboard.
- **Animated splash** (`SplashView`): the same logo and background, so the hand-off is seamless. A mint scan line sweeps over the car, the corner brackets lock on, then the "Carlyze · AI Car Inspection" wordmark appears (about 1.9 s).
- **Icon:** a car inside scan brackets, with a scan line and a verified check, on a navy-to-teal gradient. It reads well at 60 px and stands apart from the red/blue icons common in this category. Regenerate or tweak it with `MLTraining/generate_icon.py`.

## 7. App Store ASO

| Field | Value | Chars |
|---|---|---|
| **App name** | `Carlyze: AI Car Inspection` | 26/30 |
| **Subtitle** | `Used Car Check & Damage Scan` | 28/30 |
| **Keywords** | `vin,accident,repaint,paint,engine,sound,obd2,tyre,tire,dent,scratch,buyer,dealer,report,vehicle,auto` | 100/100 |
| Category | Primary: Utilities · Secondary: Productivity (less crowded than Navigation/Lifestyle for this intent) |
| Promo text (170) | "New: engine sound AI & suspension bounce test. Find repainted panels, replaced windscreens and hidden accident repairs before you buy." |

Why this setup works:
- The name carries the highest-weight search terms, "AI Car Inspection". The subtitle adds "used car check", "damage scan" and "car check". Apple indexes title + subtitle + keywords together, so no word is repeated and the full 100 characters are used.
- "Carlyze" is a short, unique, pronounceable brand ("car" + "analyze"). Before settling on it I checked alternatives: **VeriCar, CarspecT, CarScope, CarXray and CarVerdict are already used** by existing apps or sites.
- Localise the name and subtitle for your biggest markets (e.g. Urdu/Arabic storefronts: "Car Inspection" → local terms like "گاڑی چیک"). Each locale gets its own 100-character keyword field, and the extra locales Apple indexes for a storefront roughly double your keyword space.
- Screenshots: 1) the body map with coloured panels ("See every repainted panel"), 2) the ratings card ("Engine 9.4 · Tyres 8.8 · Suspension 10"), 3) the glass stamp finding ("Replaced windscreen detected"), 4) the engine sound waveform, 5) the PDF report.
- Before you submit, check that the name is free in App Store Connect and the trademark is clear in your target countries.
