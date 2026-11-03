# Morph Live Activities API (v1)

A local HTTP API that lets scripts and apps on this Mac show activities on the island.

It's **off by default**. While it's off, no socket exists. Turn it on in Settings → Activities, then copy the token from the same screen.

## Connecting

| | |
| --- | --- |
| Address | `http://127.0.0.1:47800`, with the port changeable in Settings |
| Authorization | `Authorization: Bearer <token>` on every request |
| Body | JSON, 4 KB at most |
| Version | In the path: `/v1/` |

The listener binds the loopback address, so it can't be reached from another machine. That's why it's plain HTTP: traffic never leaves the Mac. Use `127.0.0.1` or `localhost`.

### Why HTTP and not XPC

XPC suits components of one app, or of one signing team. Scripts in curl or Python can't use it, and they're the main audience, so a loopback socket with a token is the one interface. If a native companion app ever ships alongside Morph, XPC would be the better choice for it.

## Endpoints

| Method and path | Does | Success |
| --- | --- | --- |
| `GET /v1/capabilities` | Lists icons, states, priorities and limits | `200` |
| `POST /v1/activities` | Creates an activity | `201` |
| `PATCH /v1/activities/{id}` | Updates the fields sent | `200` |
| `DELETE /v1/activities/{id}` | Ends an activity | `204` |

## Fields

| Field | Type | Rules |
| --- | --- | --- |
| `id` | text | Required to create. Up to 64 letters, digits, `.`, `_` or `-`. Can't change |
| `title` | text | Required to create. Up to 80 characters, no control characters |
| `subtitle` | text | Up to 120 characters |
| `icon` | text | A short name from `/v1/capabilities`. Never a path or an arbitrary symbol |
| `progress` | number | 0 to 1 |
| `duration` | whole number | Seconds until it expires, 1 to 3600. Default 300 |
| `priority` | text | `low`, `normal` or `high` |
| `state` | text | `running`, `paused`, `success` or `failed` |

Any other field is an error, so a typo can't pass silently.

**Expiry.** Each activity ends by itself when its time is up, so a script that crashes can't leave anything behind. Every `PATCH` restarts the clock, using `duration` if sent and the 300 second default otherwise.

**Priority.** `priority` only orders your activities among each other. Morph decides the effective priority, always below timers, volume, screenshots and alerts, so no request can interrupt something important.

**What appears when.** Creating an activity shows a short banner. Afterwards it stays beside the notch while nothing more important is there, and in the panel's Activities tab. Progress updates don't show banners. Ending with `state` set to `success` or `failed` shows one final banner, so `PATCH` the state before you `DELETE`.

## Errors

Errors are JSON: `{"error": "description"}`.

| Status | Means |
| --- | --- |
| `400` | Invalid JSON, field or header |
| `401` | Missing or wrong token |
| `403` | Sent by a browser (any `Origin` header), or a `Host` other than this server |
| `404` | No such activity or route |
| `405` | Method not allowed on that path |
| `409` | That `id` is already open |
| `413` | Body over 4 KB |
| `429` | Rate limited, too many failed tokens, or 8 activities already open |
| `431` | Headers over 8 KB |
| `501` | `Transfer-Encoding` isn't supported |

## Limits

- 10 requests per second, with bursts up to 30.
- 8 open activities and 8 simultaneous connections.
- 10 failed authorizations, recovering at one every 6 seconds.
- 5 seconds for a connection to finish. One request per connection.

## Security

- **Token:** 256 random bits, kept in your Keychain and compared in constant time. Regenerate it in Settings to cut off everything using the old one.
- **Browsers:** a web page can reach loopback, so requests with `Origin` are refused and no CORS headers exist. Checking `Host` stops DNS rebinding.
- **Nothing runs:** the API executes no commands and opens no files. No field is treated as a path.
- **Any local process that has the token can show activities.** Treat it like a password, and don't commit it.

## Examples

Tested against the real server: [`curl`](examples/activity.sh), [`Python`](examples/activity.py) and [`Swift`](examples/activity.swift).

```bash
export MORPH_TOKEN='paste-from-settings'
curl -X POST http://127.0.0.1:47800/v1/activities \
  -H "Authorization: Bearer $MORPH_TOKEN" -H 'Content-Type: application/json' \
  -d '{"id":"upload-001","title":"Enviando arquivo","subtitle":"Morph API","progress":0.65,"state":"running"}'
```
