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
  the same one).
- `client_id` (a UUID) makes the call idempotent: repeating it updates the same
  entry instead of adding another. `started_at` is then required.
- Entries show up live for everyone. They are credited to the integration, not
  to the caregiver who made the token: the app shows them as "Other" with a
  bolt icon (hover for the token's name), and the API returns the token's name
  as `logged_via` (`null` when a person logged it).
