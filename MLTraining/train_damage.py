"""
Train the exterior DAMAGE detector (CarDamageYOLO.mlpackage) and export to Core ML.

Dataset: CarDD (USTC, 4,000 images / 9,000+ labelled damages: dent, scratch, crack,
glass shatter, lamp broken, tire flat) — https://cardd-ustc.github.io/
A YOLO-format conversion is on Kaggle: "CarDD with YOLO Annotations (Images + Labels)".
CarDD is licensed for NON-COMMERCIAL research use: for a paid App Store app, request a
commercial licence from the authors or train on your own labelled photos (recommended anyway
— add 2–5k photos from your target market, incl. rust, and repaint-mismatch examples).

    pip install ultralytics coremltools
    python train_damage.py --data cardd.yaml
"""
import argparse
from ultralytics import YOLO

# Class names MUST match DamageType raw values in the app.
NAMES = ["dent", "scratch", "crack", "glass_shatter", "lamp_broken", "tire_flat", "rust"]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default="cardd.yaml")        # yaml with train/val paths + names above
    ap.add_argument("--model", default="yolo11s.pt")       # s = good speed/accuracy on iPhone ANE
    ap.add_argument("--epochs", type=int, default=150)
    ap.add_argument("--imgsz", type=int, default=640)
    a = ap.parse_args()

    model = YOLO(a.model)
    model.train(data=a.data, epochs=a.epochs, imgsz=a.imgsz, batch=16, patience=30,
                # Damage is small & reflective — strong colour/lighting augmentation matters
                hsv_h=0.015, hsv_s=0.6, hsv_v=0.5, degrees=5, scale=0.5, mosaic=1.0, mixup=0.1,
                close_mosaic=15, cos_lr=True)
    model.val()
    # nms=True → Vision returns VNRecognizedObjectObservation directly (what ObjectDetector expects)
    model.export(format="coreml", nms=True, imgsz=a.imgsz, half=True)
    print("Rename the exported .mlpackage to CarDamageYOLO.mlpackage and drag it into the Xcode target.")

if __name__ == "__main__":
    main()
