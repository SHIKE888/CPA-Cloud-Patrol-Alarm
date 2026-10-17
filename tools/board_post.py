import json
import sys
import urllib.request

path = sys.argv[1]
args = sys.argv[2:]
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
req = urllib.request.Request("http://127.0.0.1:9012" + path, data=body,
                             headers={"Content-Type": "application/json"})
try:
    with urllib.request.urlopen(req, timeout=60) as r:
        print(r.status)
        print(r.read().decode())
except Exception as e:
    print("ERR", type(e).__name__, e)
    if hasattr(e, "read"):
        print(e.read().decode())
