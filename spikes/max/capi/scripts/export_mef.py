import sys
from pathlib import Path
from max import engine
from max.driver import CPU
s = engine.InferenceSession(devices=[CPU()])
m = s.load(Path(sys.argv[1]))
m._export_mef(sys.argv[2])
print("exported", sys.argv[2])
