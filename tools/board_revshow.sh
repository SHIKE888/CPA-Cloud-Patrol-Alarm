#!/bin/sh
curl -s -m 6 http://127.0.0.1:9012/api/sys | /opt/miniforge3/envs/mlk-ov/bin/python -c "
import sys, json
d = json.load(sys.stdin)
print('rev    :', d.get('rev'))
print('clients:', d.get('clients'), ' frame_id:', d.get('frame_id'), ' fps:', d.get('fps'))
"
