"""
Train the CAR PARTS detector (CarPartsYOLO.mlpackage).

Start: Ultralytics' public "carparts-seg" dataset (23 classes: doors, bumpers, hood, glass,
lights, mirrors, trunk/tailgate, wheel) — downloaded automatically by `data="carparts-seg.yaml"`.
Detection training reads its polygons as boxes.

To get the full per-panel report (fenders, quarter panels, left/right wheels) add your own
labelled images with these extra class names (CVAT / Roboflow / Label Studio):
  front_left_fender, front_right_fender, back_left_quarter, back_right_quarter, roof,
  front_left_wheel, front_right_wheel, back_left_wheel, back_right_wheel,
  front_left_window, front_right_window, back_left_window, back_right_window
Names must match CarPart.init(modelLabel:) in the app.

    python train_parts.py                      # public dataset only
    python train_parts.py --data my_parts.yaml # merged dataset
"""
import argparse
from ultralytics import YOLO

ap = argparse.ArgumentParser()
ap.add_argument("--data", default="carparts-seg.yaml")
ap.add_argument("--epochs", type=int, default=120)
a = ap.parse_args()

m = YOLO("yolo11s.pt")
m.train(data=a.data, epochs=a.epochs, imgsz=640, batch=16, fliplr=0.0,  # NO horizontal flip: it swaps left/right labels!
        hsv_v=0.4, degrees=3, cos_lr=True)
m.export(format="coreml", nms=True, imgsz=640, half=True)
print("Rename to CarPartsYOLO.mlpackage and add to the Xcode target.")
