import json
import urllib.request

d = json.load(urllib.request.urlopen("http://127.0.0.1:9012/api/fpga"))
print(d["phys"])
print("SHR0 regs", d["regs"]["CAM_EXP_L"], d["regs"]["CAM_EXP_M"], d["regs"]["CAM_EXP_H"])
print("VER", hex(d["status"]["VER"]), "RES_MODE", d["regs"]["RES_MODE"])
