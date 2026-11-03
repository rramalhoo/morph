#!/usr/bin/env python3
"""Create, update and end a Morph activity using only the standard library.

Usage: MORPH_TOKEN=... [MORPH_PORT=47800] python3 activity.py
"""
import json
import os
import time
import urllib.error
import urllib.request

API = f"http://127.0.0.1:{os.environ.get('MORPH_PORT', '47800')}/v1"
TOKEN = os.environ["MORPH_TOKEN"]


def call(method, path, body=None):
    request = urllib.request.Request(
        API + path,
        method=method,
        data=None if body is None else json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=3) as response:
            payload = response.read()
            return json.loads(payload) if payload else None
    except urllib.error.HTTPError as error:
        raise SystemExit(f"{error.code}: {error.read().decode()}")


call("POST", "/activities", {"id": "python-001", "title": "Treinando modelo", "icon": "cpu", "progress": 0.0})
for step in range(1, 5):
    time.sleep(0.2)
    print(call("PATCH", "/activities/python-001", {"progress": step / 4}))
call("PATCH", "/activities/python-001", {"state": "success"})
call("DELETE", "/activities/python-001")
print("done")
