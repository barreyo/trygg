# REST API

A small JSON API for scripts and integrations (Home Assistant, Shortcuts, a
baby-monitor bridge) to read and log for a family.

## Authentication

Create a token on a child's **Sharing** page, under **API access**. Any
caregiver can; a token acts as the person who made it, inside that one family,
and never with more access than they have:

| Token access | Can                                              |
| ------------ | ------------------------------------------------ |
| Read only    | list children and read their log                 |
| Read and log | also add, stop and delete entries                |

Tokens can't manage people, invites or children — that stays in the app. A
token stops working when its issuer leaves the family, and drops to read-only
if they are made a viewer. Revoke one from the same page. The secret is shown
once; only a hash is stored.

```sh
curl -H "Authorization: Bearer trygg_…" https://<host>/api/v1/children
```

A missing, unknown, revoked or expired token is `401`. A child outside the
token's family is `404`, the same as one that doesn't exist; a token without
enough access is `403`. Errors are `{"errors": {...}}`.

## Endpoints

| Method   | Path                                         | Notes                                                   |
| -------- | -------------------------------------------- | ------------------------------------------------------- |
| `GET`    | `/api/v1/children`                           | The family's children                                   |
| `GET`    | `/api/v1/children/:id`                       |                                                         |
| `GET`    | `/api/v1/children/:id/entries`               | Newest first. `type`, `since`, `until` (ISO 8601), `limit` (default 50, max 200) |
| `POST`   | `/api/v1/children/:id/entries`               | Log an entry (below). `201`                             |
| `POST`   | `/api/v1/children/:id/entries/:entry_id/stop`| Stop a running sleep. Optional `ended_at`, `data`, `note`. `409` if not running |
| `DELETE` | `/api/v1/children/:id/entries/:entry_id`     | `204`                                                   |
| `GET`    | `/api/v1/devices`                            | The family's sensor devices with their latest reading   |
| `POST`   | `/api/v1/devices/:hardware_id/readings`      | Report a sensor sample (below). `201`                   |

### Firmware

The M5Stack button ([`firmware/`](../firmware/README.md)) updates itself from two endpoints,
which accept any valid token:

| Method | Path                              | Notes                                                       |
| ------ | --------------------------------- | ----------------------------------------------------------- |
| `GET`  | `/api/v1/firmware/button`         | `{"version", "size", "md5"}` of the current release; `404` if none |
| `GET`  | `/api/v1/firmware/button/image`   | The image, with its MD5 in `x-md5`                          |

### Sensor devices

An M5Stack with an ENV Pro unit reports room readings. The device identifies itself by `hardware_id`
(its WiFi MAC address); the first reading from an unknown id **registers** a device in the token's
family with no name and a random five-digit `short_id`, and a caregiver names it in the app (menu →
Devices) so the family knows which room it is in. The response to a reading carries the device, so
the unit can print its `short_id` on its screen (the button does, small, in the top right corner).
A caregiver can also pin a device to the Today screen as a live widget. Needs a **Read and log**
token.

```sh
curl -X POST "https://<host>/api/v1/devices/AA:BB:CC:DD:EE:FF/readings" \
  -H "Authorization: Bearer trygg_…" -H "Content-Type: application/json" \
  -d '{"model": "env_pro", "temperature_c": 21.4, "humidity_pct": 46, "pressure_hpa": 1012, "gas_ohms": 91000,
       "iaq": 48, "iaq_accuracy": 3, "co2_ppm": 620, "voc_ppm": 0.6}'
```

- Any of `temperature_c` (-40…85), `humidity_pct` (0…100), `pressure_hpa` (300…1100) and `gas_ohms`
  (raw gas resistance). A device running Bosch's BSEC also sends `iaq` (static indoor air quality,
  0 clean … 500 bad), `iaq_accuracy` (0 still learning … 3 calibrated to the room), `co2_ppm` and
  `voc_ppm` (CO2 and breath-VOC *equivalents*, estimated from the gas sensor). At least one is
  required, out-of-range values are `422`. `measured_at`
  (ISO 8601) defaults to now; `model` is stored on the device.
- Every reading is broadcast to open screens of the family, which update live. Readings older than
  30 days are deleted. Forgetting a device in the app deletes its readings; if it keeps reporting it
  registers again, unnamed.
- `GET /api/v1/devices` returns `{id, hardware_id, short_id, name, model, last_seen_at, latest}` per device
  (`name` is `null` until named).

### Logging an entry

```sh
curl -X POST https://<host>/api/v1/children/1/entries \
  -H "Authorization: Bearer trygg_…" -H "Content-Type: application/json" \
  -d '{"type": "feeding", "data": {"amount_ml": 120, "bottle_contents": "formula"}}'
```

- `type`: `feeding` (bottle; needs `data.amount_ml`), `diaper` (`data.kind`:
  `pee`, `poo` or `mixed`) or `sleep`.
- `started_at` defaults to now; `ended_at` is for completed sleeps. A `sleep`
  with no `ended_at` starts the child's running timer (starting it twice returns
  the same one). A `sleep` may carry `data.location` (`bassinet`, `crib`,
  `contact`, `stroller`, `other`) and `data.cue`, how sleepy the baby looked when
  it started: `tired`, `ready` or `overtired`. Unknown values are dropped.
- `client_id` (a UUID) makes the call idempotent: repeating it updates the same
  entry instead of adding another. `started_at` is then required.
- Entries show up live for everyone. They are credited to the integration, not
  to the caregiver who made the token: the app shows them as "Other" with a
  bolt icon (hover for the token's name), and the API returns the token's name
  as `logged_via` (`null` when a person logged it).
