# Transfers, AirDrop and iPhone Continuity (Morph 3.1)

## What Morph can actually see

| Source | How | Real progress? |
| --- | --- | --- |
| Browser downloads | The folder you choose in Settings › Transfers. Partial files (`.download` Safari, `.crdownload` Chromium, `.part` Firefox) mean "in progress"; the finished file must carry a fresh `com.apple.quarantine` marker | Bytes and speed always; a percentage only when the size is known (Safari records it in the partial) |
| Uploads and other transfers | Scripts or apps report them to `/v1/transfers` on the local API | Whatever the sender reports |
| AirDrop sent | Shelf › AirDrop, through `NSSharingService` | No. macOS reports only "finished" or "failed" |
| AirDrop received | A new file in the watched folder whose quarantine agent is `sharingd` | No. Shown once the file has arrived |
| iPhone activities | Morph Companion on a paired iPhone | Whatever the sender reports |

Not possible with public APIs, so not attempted: reading other apps' network traffic, browser history or download databases, AirDrop progress or the sender's name, and the Live Activities other apps show on the iPhone or that macOS mirrors from it (ActivityKit only lets an app read its own; there's no API to read mirrored ones).

## Transfers API

Same server, token, limits and Host/Origin checks as the activities API. It stays off until the local API is on in Settings › Activities, and `/v1/transfers` also needs *Show Uploads* on.

| Method and path | Body | Success |
| --- | --- | --- |
| `POST /v1/transfers` | `id`, `name`, `kind` (`download`/`upload`), optional `bytes`, `total`, `state` | `201` |
| `PATCH /v1/transfers/{id}` | any of `name`, `bytes`, `total`, `state`, `error` | `200` |
| `DELETE /v1/transfers/{id}` | | `204` (ends as cancelled) |

`state` is `pending`, `transferring`, `paused`, `completed`, `failed` or `cancelled`. Unknown fields are refused, `bytes` can't exceed `total`, and nothing is treated as a path. Morph never offers Cancel for these: it doesn't control them.

### curl

```sh
TOKEN=... ; API=http://127.0.0.1:47800/v1/transfers
curl -s -X POST $API -H "Authorization: Bearer $TOKEN" -d '{"id":"up1","name":"video.mov","kind":"upload","total":52428800}'
curl -s -X PATCH $API/up1 -H "Authorization: Bearer $TOKEN" -d '{"bytes":26214400}'
curl -s -X PATCH $API/up1 -H "Authorization: Bearer $TOKEN" -d '{"state":"completed"}'
```

### Python

```python
import json, os, urllib.request

API = "http://127.0.0.1:47800/v1/transfers"
TOKEN = os.environ["MORPH_TOKEN"]

def call(method, path="", body=None):
    request = urllib.request.Request(API + path, method=method, data=json.dumps(body).encode() if body else None,
                                     headers={"Authorization": f"Bearer {TOKEN}"})
    with urllib.request.urlopen(request) as response:
        return response.status

total = os.path.getsize("backup.tar")
call("POST", body={"id": "backup", "name": "backup.tar", "kind": "upload", "total": total})
# ... after each chunk your uploader sends:
call("PATCH", "/backup", {"bytes": total // 2})
call("PATCH", "/backup", {"state": "completed"})
```

### Swift

```swift
import Foundation

func report(_ method: String, _ path: String = "", _ body: [String: Any]) async throws {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:47800/v1/transfers" + path)!)
    request.httpMethod = method
    request.setValue("Bearer \(ProcessInfo.processInfo.environment["MORPH_TOKEN"]!)", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    _ = try await URLSession.shared.data(for: request)
}

try await report("POST", ["id": "sync", "name": "Photos", "kind": "upload", "total": 1_000_000])
try await report("PATCH", "/sync", ["bytes": 400_000])
try await report("PATCH", "/sync", ["state": "completed"])
```

Webhooks from outside services aren't received by Morph directly. Run your own relay on this Mac that receives them and calls this API: Morph never opens a port to the internet.

## Morph Continuity

### Pairing and security

1. On the Mac: Settings › Continuity › Enable iPhone Sync, then **Pair iPhone…**. A QR code appears; it holds a fresh 256-bit secret, expires in five minutes and works once.
2. On the iPhone: scan it with the Camera app (it opens Morph Companion) or paste the link.
3. The two run an X25519 key exchange over the local network, each proving it knows the secret with HMAC-SHA256. The secret itself never crosses the network. The resulting device key is stored in the Keychain on both sides (`ThisDeviceOnly`).
4. Every connection derives fresh per-direction ChaCha20-Poly1305 keys from the device key and two random nonces. Messages carry rising sequence numbers; replayed, reordered, reflected or altered frames close the connection.

Other protections: Bonjour on the local network only, connections from non-local addresses refused, 16 KB frames, eight connections, eight activities per device, 10 messages/s with a burst of 30, a shared budget for failed pairings and unknown devices, every field validated, icons from a fixed list. **Disconnect Device** on the Mac deletes the key and drops its connection and activities; it must pair again.

### Activity lifecycle

An activity lives for its `lifetime` (default 30 minutes, at most 4 hours) after its last update. If the iPhone disconnects, its activities are marked out of sync and end after two minutes unless it reconnects and updates them. iOS suspends the Companion in the background, so sync runs while the app is open.

### What the Companion sends

Activities the user creates in the app, and ones a Shortcut sends with **Send Activity to Mac**, which is the documented way for automations and other apps' Shortcuts actions to feed it. It doesn't read other apps' Live Activities or notifications.

## Permissions

| Permission | Why | When |
| --- | --- | --- |
| Folder access (security-scoped bookmark, read-only) | Watching the downloads folder you pick | When you choose it |
| Local Network (Mac and iPhone) | Continuity's Bonjour listener and connection | First time sync is enabled or the Companion connects |
| Keychain | Device keys | Automatic, no prompt |

No new sandbox entitlements: `network.server` and user-selected read-only file access already existed.
