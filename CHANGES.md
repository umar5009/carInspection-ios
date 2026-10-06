# Carlyze: changes in this version

## Trust fixes
- Camera-only colour differences are now a **"Check" (C)** mark, not a repaint. They are capped in the accident score, so on their own they can never go past "minor" or produce grade **R**. Only a paint gauge reading can say *Repainted* or *Filler*.
- Panels are compared only with **comparable** panels: sides with sides, never the bonnet with the fenders (the bonnet faces the sky and always looks different).
- **Odd-one-out attribution**: when one door is repainted, only that door is flagged, not the fender and door beside it.
- Glare is removed before colour is measured (brightest 15 % of pixels dropped).
- Gauge baseline = roof, else the median of readings, capped at 140 µm so a fully re-sprayed ("shower") car is still caught. There is also a "full repaint" note when 6+ panels are repainted.

## AR paint scan (new)
- ARKit world tracking replaces the drifting compass: the side of the car stays correct for the whole walk-around.
- Panels are found by `CarPartsYOLO` anywhere in the frame. Without the model, a framing guide is used, but only after Vision confirms a car is in view.
- A difference must hold for 3 frames **and** from 2 viewing angles (≥ 12° apart), so moving reflections are ignored.
- Flagged and measured panels get floating AR labels.
- **Crosshair gauge targeting**: aim at a panel, measure, and the reading is saved to that panel. Works with BLE gauges, keyboard-mode (HID) gauges, or typing. Plastic bumpers are refused.

## Now reachable
- Home has **Quick guided inspection** and **Full inspection** (AR scan, gauge, OBD, suspension, checklist).
- After a quick inspection, **Verify** opens the full hub with everything already captured.

## Smaller fixes
- Glass: the brand check now works with 2 stamps (the guided flow only takes 2).
- OBD: per-command timeouts, pending codes (mode 07), recently-cleared-codes detection (readiness monitors, warm-ups and distance since clearing), ECU odometer (PID A6), compared with the dashboard reading.
- JDM chassis numbers (e.g. `NZE141-1234567`) are recognised as well as VINs.
- Odometer OCR prefers the ODO/km line and skips trip meters.
- Side-less model labels (`front_door`, `back_door`, `front_light`, `back_light`) are resolved from the scanned side instead of being dropped or put on the wrong side.
- Report: evidence photos with panel and damage outlines, a camera-only caveat on the accident card, OBD details, and damage that could not be tied to a panel.
- Old saved reports still open: every new report field is optional.

## Not done yet
- Trained models are not included; train them with `MLTraining/`.
- BLE gauges that send binary packets need a decoder in `PaintGaugeService.decodeBinary(_:)`.
- Urdu localisation, a price-impact guide and shareable cloud reports.
- The PDF export still splits long cards across pages.
