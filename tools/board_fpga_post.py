import json
import sys
import urllib.request

url = "http://127.0.0.1:9012/api/fpga"
args = sys.argv[1:]
patch = {}
for i in range(0, len(args), 2):
    k = args[i]
    v = args[i + 1]
    try:
        v = float(v) if "." in v else int(v)
    except ValueError:
        pass
    patch[k] = v
body = json.dumps(patch).encode()
req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"})
try:
    with urllib.request.urlopen(req, timeout=10) as r:
        print(r.status)
        print(r.read().decode())
except Exception as e:
    print("ERR", type(e).__name__, e)
    if hasattr(e, "read"):
        print(e.read().decode())
