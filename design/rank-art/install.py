"""Copies the finished badges (out/final/rank-<rank>-badge.png) into the iPhone app's asset catalogue as
rank-<rank> image sets. Run after process.py:

    python install.py
"""
import json
import os
import shutil

HERE = os.path.dirname(os.path.abspath(__file__))
FINAL = os.path.join(HERE, "out", "final")
ASSETS = os.path.join(HERE, "..", "..", "native", "CheatDays", "Assets.xcassets")

for rank in ["crumb", "toast", "dumpling", "burger", "feast", "legend"]:
    src = os.path.join(FINAL, f"rank-{rank}-badge.png")
    if not os.path.exists(src):
        print(f"  {rank}: no badge yet")
        continue
    folder = os.path.join(ASSETS, f"rank-{rank}.imageset")
    os.makedirs(folder, exist_ok=True)
    shutil.copy(src, os.path.join(folder, f"rank-{rank}.png"))
    with open(os.path.join(folder, "Contents.json"), "w") as f:
        json.dump({"images": [{"idiom": "universal", "filename": f"rank-{rank}.png"}], "info": {"author": "xcode", "version": 1}}, f, indent=2)
    print(f"  {rank}: installed")
