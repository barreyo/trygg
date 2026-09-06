# Sleep prediction — implementation plan

Turns the recommendations in `docs/sleep-prediction-research.md` §3 into phased,
independently shippable work. Each phase is a PR, keeps `mix precommit` green,
and only adds keys to the `Insights.summarize/4` result (never removes).

## Where the code lives

| Concern | Module |
|---|---|
| Age priors, sanity floors | `lib/trygg/reports/norms.ex` |
| Per-day segmentation (naps, wake windows, clusters) | `lib/trygg/reports/day.ex` |
| Stats over a window + `predict/4` | `lib/trygg/reports/insights.ex` |
| Robust descriptive stats | `lib/trygg/reports/stats.ex` |
| Public API (`summary/4`, `outlook/3`) | `lib/trygg/reports.ex` |
| Home-screen rendering of the prediction | `lib/trygg_web/live/dashboard_live.ex` (`next_nap/2`, `wake_pressure/2`) |
| Tests | `test/trygg/reports/{insights,norms,day}_test.exs` |

Key constraint: `Trygg.Reports` is **derived, nothing persisted**. Only Phase 0
changes that, and it does so in a new module so the rest stays pure.

`predict/4` in `insights.ex` is called from `summary/4`, which the dashboard
runs on mount and on every 60 s tick — added work must stay O(days).

---

## Phase 0 — Prediction ledger (no behaviour change) — ✅ DONE

Shipped in this branch:

- Migration `20260906120000_create_sleep_predictions.exs` — `sleep_predictions`
  table, unique on `(child_id, kind, made_from_ts)`.
- `Trygg.Reports.Prediction` schema (`lib/trygg/reports/prediction.ex`).
- `Trygg.Reports.PredictionLedger` (`.../prediction_ledger.ex`) —
  `track/2` (record open + reconcile matured), `sweep/1`, `accuracy/3`
  (recency-weighted MAE + signed bias).
- `Trygg.Reports.PredictionWorker` — Oban worker; `%{child_id}` args → one
  child, no args → sweep. `unique` collapses bursts.
- `Trygg.Log` enqueues the worker after every `:sleep` write, config-gated by
  `config :trygg, Trygg.Reports, track_predictions:` (true in dev/prod, false
  in test — tests call `PredictionLedger.track/2` directly).
- `Trygg.Reports.Insights` prediction map gained `anchor_ts` (the wake a
  prediction keyed off) and a `source` on the `bedtime` sub-map — additive.
- Oban Cron in `config/prod.exs`: `*/30 * * * *` sweep as a backstop.
- Tests: `test/trygg/reports/prediction_ledger_test.exs`,
  `.../prediction_worker_test.exs`. `mix precommit` green (478 tests).

Not yet done (follow-ups for this phase): surfacing
`PredictionLedger.accuracy/3` in the dashboard copy once real rows exist.

### Original design notes

**Goal:** record every "next nap" / "bedtime" prediction and reconcile it
against what actually happened, so later phases can measure error, tighten or
widen the shown range honestly, and de-bias the point estimate. This is the
"gets better over time" substrate; ship it first so data accrues while the rest
is built.

### Data model

Migration `*_create_sleep_predictions.exs`:

```
sleep_predictions
  id
  child_id            references children, on_delete: delete_all
  kind                :string   -- "next_nap" | "bedtime"
  made_at             utc_datetime  -- when we predicted
  made_from_ts        utc_datetime  -- the wake/last-sleep-end the prediction keyed off
  ordinal             integer, null -- nap number for :next_nap
  source              :string   -- "history" | "age_prior" | "blended"
  target_ts           utc_datetime  -- predicted sleep-onset
  range_lo_ts         utc_datetime, null
  range_hi_ts         utc_datetime, null
  actual_ts           utc_datetime, null  -- filled on reconciliation
  error_seconds       integer, null       -- actual - target (signed)
  resolved_at         utc_datetime, null
  inserted_at / updated_at
  index (child_id, kind, resolved_at)
  unique (child_id, kind, made_from_ts)   -- one open prediction per wake per kind
```

### Modules

- `Trygg.Reports.PredictionLedger` — `record/1`, `reconcile_child/2`,
  `accuracy/2` (returns `%{mae_seconds, bias_seconds, n}` per kind, over the
  last ~30 resolved rows, recency-weighted).
- `Trygg.Reports.PredictionWorker` (Oban, queue `:reminders` or a new
  `:predictions`) — given a `child_id`: rebuild today's `Insights` prediction,
  `record/1` the open `next_nap` + `bedtime`, then `reconcile_child/2` any
  matured rows (an open row whose `made_from_ts` is followed by a real sleep
  start → set `actual_ts`, `error_seconds`, `resolved_at`).

### Wiring (no compile cycle)

`Trygg.Log` already broadcasts `{:log, action, entry}` on `child:<id>` and is a
dependency of `Reports`, not the reverse. On a `:sleep` entry create/close,
`Trygg.Log` enqueues `PredictionWorker` with the `child_id` (same pattern as the
weight-reminder enqueue). The worker is the only thing that touches `Reports`.
Fallback/cleanup: Oban Cron sweeps active children every ~30 min to reconcile
rows missed by a dropped broadcast.

### Tests

- `PredictionLedgerTest`: record → open row; a later sleep start resolves it
  with the right signed `error_seconds`; no matching sleep leaves it open;
  unique constraint dedupes re-runs for the same wake.
- `PredictionWorkerTest`: `Oban.Testing` `:manual`; enqueue on sleep events;
  idempotent.

### Optional surface

Once ~5 resolved rows exist, dashboard copy: "Recent nap predictions within
±`N` min." Pure read via `PredictionLedger.accuracy/2`. Gate behind a helper so
it stays hidden until the sample is real.

**Risk:** low — additive table, worker isolated. Watch Oban queue volume
(one job per sleep log per child — trivial).

---

## Phase 1 — Continuous priors + smooth prior→history blend — ✅ DONE

Shipped in this branch:

- `Trygg.Reports.Stats` — `weighted_quantile/3`, `weighted_median/2`,
  `effective_n/1` (Kish).
- `Trygg.Reports.Norms` — `wake_window_range/1` is now linear interpolation
  between 15 age anchors (no step discontinuities); new `typical_nap_count/1`
  (4→3→2→1), `wake_window_position_factor/2`, `min_wake_window_seconds/1`,
  `max_naps/1`. Position factor + floors are defined but only wired into
  Insights in Phase 2.
- `Trygg.Reports.Insights` prediction path:
  - `@recency_window_days 21`, `@recency_half_life_days 6` — each recent day is
    weighted `0.5 ^ (days_ago / 6)`; the 14-day hard slice is gone.
  - `recency_weights/2` + `weighted_wake_stats/1` + `weighted_nap_stats/2`
    replace the plain `wake_stats`/`nap_stats` in `recent_stats` (the
    descriptive top-level `naps`/`wake_windows` keys still use the old
    equal-weight path — unchanged).
  - `wake_estimate/2` is a shrinkage blend: `w = eff_n / (eff_n + 3)`,
    `typical = w·history + (1−w)·prior_mid`, range blended likewise.
    `source` = `:history` (eff_n ≥ 5) / `:age_prior` (eff_n < 1) / `:blended`.
  - `typical_nap_count/1` blends the weighted history count with
    `Norms.typical_nap_count(age_days)` — so a day-0 child with a logged wake
    now gets a next-nap prediction instead of `nil`.
- Tests updated/added: `norms_test` (interpolation continuity, monotonic lower
  bound, nap-count steps, position factor); `insights_test` (blended source,
  no-history child still predicts, recency dominates). `mix precommit` green
  (483 tests).

Consumer note: `dashboard_live.ex` / `reports_live.ex` still branch only on
`source == :age_prior`; a `:blended` copy branch ("still learning …") is a
small follow-up, not yet done.

### Original design notes

Fixes: day-0 children get no nap prediction; predictions lurch at the 90/150/210-day
prior boundaries; the hard `@min_sample = 3` cliff.

### `Norms`

- Rewrite `wake_window_range/1` to **linear-interpolate in `age_days`** between
  anchor points (research brief §3.3 table) instead of `cond` bands. Same
  return contract: `{lo_seconds, hi_seconds}` or `nil` outside the infant range.
- Add `typical_nap_count(age_days)` → integer, from the §1.5 table
  (4 → 3 → 2 → 1 across the year), `nil` when age unknown.
- Add `wake_window_position_factor(ordinal, expected_naps)` → float
  (`~0.82` first window, `1.0` middle, `~1.2` last-before-bed); linear for the
  ones between.
- Add explicit floors: `min_wake_window_seconds(age_days)` (newborn 30 min,
  rising), `max_naps(age_days)`.
- Extend `norms_test.exs`: monotonic non-decreasing lower bound across the first
  year, continuity (no jump > a few min between consecutive days), floors hold.

### `Stats`

- `weighted_median(values, weights)` and `weighted_quantile(values, weights, p)`
  (interpolated, matching `percentile/2` semantics).
- `effective_n(weights)` = `(Σw)² / Σw²` (Kish) — used for the blend weight.

### `Insights`

Only the **prediction subtree** changes; the descriptive stats
(`totals`, `heatmap`, `night_wakings`, …) keep the current `ready?` gate.

- In `recent_stats`, attach a per-day recency weight
  `0.5 ^ (days_ago / @recency_half_life_days)` with `@recency_half_life_days 6`,
  and drop the hard 14-day slice to ~21 days as a cheap pre-filter.
- `wake_estimate/2`: compute
  `w = eff_n / (eff_n + @blend_k)` (`@blend_k 3`),
  `typical = w * weighted_history_median + (1 - w) * prior_mid`,
  `range` widened toward the prior band as `w → 0`.
  `source: :history | :blended | :age_prior` by which term dominates
  (`w > 0.8`, `0.2..0.8`, `< 0.2`).
- `typical_nap_count/1`: `round(w * history_median + (1 - w) *
  Norms.typical_nap_count(age_days))`; no longer returns `0` just because
  history is thin, so `next_nap_prediction` fires on day 0.
- Per-ordinal wake/nap medians used by `predict` become **weighted** medians.

### Tests

- Day-0 child (birth_date set, zero logs): `prediction.next_nap` is non-nil,
  `source: :age_prior`, target ≈ `last_wake + prior_mid`.
- 2 logged days: `source: :blended`, target between prior and history.
- 10 consistent days: `source: :history`, unchanged from today's behaviour
  (regression guard on existing tests).
- No discontinuity: a child at `age_days` 89 vs 91 with no history moves the
  target by minutes, not by the old band step.

### Consumers

`dashboard_live.ex` `next_nap/2` keys off `nap.source == :age_prior` for the
"typical for age" tag — add a `:blended` branch ("still learning `<name>`'s
pattern"). No breaking change.

**Risk:** medium — touches the core estimate. Mitigated by leaving the stats
path untouched and by the regression guard that 10-day-history output is
unchanged.

---

## Phase 2 — Position factor + sleep-pressure (catnap) feedback — ✅ DONE

Shipped in this branch (`Trygg.Reports.Insights`):

- `wake_estimate/2` → `wake_estimate/3` taking the expected nap count; the age
  prior is now scaled by `Norms.wake_window_position_factor(ordinal, expected)`
  (`position_scaled_prior/3`) — first window of the day ~0.82×, last before bed
  ~1.2×. The history side already carries position via `by_ordinal`.
- `adjust_for_last_nap/4` — after a completed nap, the next window is multiplied
  by `clamp(last_nap.seconds / weighted_nap_median(that_ordinal), 0.7, 1.15)`
  and floored at `Norms.min_wake_window_seconds(age_days)`. A 35-min catnap
  pulls the next nap markedly sooner; a long nap nudges it slightly later.
  Applied in both `next_nap_prediction` and `wake_pressure` so the "soon" copy
  and the pressure state stay consistent.
- `predict/4` threads the just-ended nap (`last_nap`) and `typical` (expected
  count) into both; `rest_schedule` uses the position factor (via
  `wake_median/3`) but a neutral catnap adj for not-yet-happened naps.
- Tests: short-vs-full nap divergence, first-window-shorter, floor clamp after
  a tiny catnap; `insights_test` age-prior case updated for the 0.82 factor.
  `mix precommit` green (485 tests).

### Original design notes

Fixes: prior is position-blind; nap *duration* is ignored when predicting the
next window (research brief §1.4, §1.6, §3.4–3.5).

### `Insights`

- `next_nap_prediction` / `wake_pressure` / `rest_schedule`: multiply the
  **prior component** of each window by
  `Norms.wake_window_position_factor(ordinal, expected_naps)`. History component
  already encodes position via `by_ordinal`.
- Catnap adjustment: after a nap closes, when predicting the following window,
  `adj = clamp(nap_len / weighted_nap_median(ordinal), 0.7, 1.15)` and
  `window = window * adj`, then clamp to `Norms.min_wake_window_seconds`.
  Short nap ⇒ earlier next nap; long nap ⇒ slightly later.
- `rest_schedule` projects with the same factor + a neutral `adj = 1.0` for
  not-yet-happened naps.

### Tests

- Same child, nap 1 of 35 min vs 90 min → next-nap target differs by a
  sensible margin, shorter nap → earlier.
- First window of the day predicted shorter than the midday window for a
  history-less child; last window longer.
- Floor holds: newborn never predicted below 30 min even after a 15-min catnap.

**Risk:** low-medium — bounded multipliers, floors enforced.

---

## Phase 3 — Clock anchoring so errors stop compounding — ✅ DONE

Shipped in this branch (`Trygg.Reports.Insights`):

- `weighted_nap_stats/3` now also emits `start_clock` (weighted median
  minutes-from-midnight) and `start_clock_iqr` per nap ordinal, via
  `minutes_from_midnight/3` + `weighted_iqr/1`.
- `anchor_to_clock/7` — when a nap ordinal's historical start clock is stable
  (`start_clock_iqr ≤ 45 min`, `eff_n ≥ 2`), the purely cumulative
  `last_wake + wake_window` target is blended toward `minutes_to_dt(clock)` by
  `clock_beta(ordinal, expected)` — ~0.2 for nap 1 rising to ~0.55 for the
  last nap, so a single early/late nap decays instead of dragging every later
  one. Clamped to never precede the morning wake.
- Wired into `next_nap_prediction` (the `range` shifts with the anchored
  target) and `rest_schedule` (each projected nap also clamped to
  `max(previous_end, now)`). `wake_pressure` is left alone — it compares
  durations, not clock times. `bedtime_prediction` already did a 50/50
  clock/from-wake blend and is unchanged.
- Tests: a 40-min-late nap 1 shifts nap 2 by <35 min and nap 3 by less still;
  erratic nap-start clocks fall back to a pure wake-window offset.
  `mix precommit` green (487 tests). No consumer changes needed.

### Original design notes

Fixes: each nap = previous end + window, so one early miss drags the whole day
(research brief §3.7). `bedtime_prediction` already blends in a clock median —
generalise it.

### `Day` / `Insights`

- `Day.naps` items already carry `start`; add `nap_start_clock_by_ordinal` to
  `nap_stats` (weighted median minutes-from-midnight per ordinal, reusing
  `minutes_from_midnight` + the bedtime-wraparound handling).
- `next_nap_prediction` and `rest_schedule`: for an ordinal with a stable
  historical start-clock (IQR under, say, 45 min),
  `target = blend(cumulative_from_wake, clock_median_dt, beta(ordinal))`
  where `beta` rises from ~0.2 (nap 1) toward ~0.55 (last nap); `bedtime`
  keeps its current ~0.5.
- Hard rule: never predict a time before `today.morning_wake` or before `now`.

### Tests

- Inject a day where nap 1 ran 40 min late; nap 2 / nap 3 / bedtime targets
  move by markedly less than 40 min (they're pulled back toward clock median).
- Child with erratic clock times (wide IQR) → falls back to pure
  cumulative-from-wake, no regression.

**Risk:** medium — changes every downstream time. Guard with a test that a
perfectly regular child's schedule is unchanged.

---

## Phase 4 — Bedtime follows the day's sleep balance; transition detection — ✅ DONE

Shipped in this branch:

- **Nap-debt bedtime** (`Insights.shift_for_nap_debt/6`): `weighted_nap_stats`
  now emits `day_total_median` (typical daytime nap sleep). When
  `day_total_median − (naps_so_far + Σ remaining nap medians) > 30 min`,
  bedtime moves earlier by `min(deficit/2, 45 min)`, floored at 18:00 local.
  `prediction.bedtime.shifted_by_seconds` reports the shift.
- **Transition flag** (`Insights.transition?/3`): true when the recency-weighted
  nap count is ≥ 0.75 below `Norms.typical_nap_count(age)`, or the last wake
  window of the day is running > 20 % above its 8–14-day-ago weighted median
  (`last_window_trend/2`). `prediction.transition?` is exposed; while true,
  every predicted range is widened ×1.5 about its centre (`widen_if/2`) in both
  `next_nap` and `wake_pressure`.
- **Regime-change + bias** (`PredictionLedger.prediction_opts/1` →
  `Insights.summarize/5` `opts`): `accuracy/3` now also returns `recent` (last
  signed errors). When the last 5 resolved errors all lean the same way and are
  each > 25 min off, the recency half-life is halved for that child; a per-kind
  `bias` (mean signed error, needs ≥ 4 rows) is applied at half strength, capped
  at ±20 min, to the `next_nap` and `bedtime` targets. `Reports.summary` and
  `PredictionLedger.track` both pass `prediction_opts/1` so the shown and the
  recorded predictions agree.
- Tests: nap-debt earlier bedtime + 18:00 floor, transition flag on a
  below-norm nap count, damped bias nudge, `prediction_opts` bias + halved
  half-life. `mix precommit` green (492 tests).

Consumer note: `dashboard_live` / `reports_live` don't yet render
`transition?` or `bedtime.shifted_by_seconds` — copy hooks for a later pass.

### Original design notes

Research brief §3.6 (tail), §3.8, §3.9 (tail).

### `Insights`

- **Sleep-balance bedtime shift:** `expected_day_sleep = day_sleep_so_far +
  Σ weighted_nap_median(remaining ordinals)`. If it trails the child's rolling
  weighted day-sleep median by > 30 min, move the bedtime target earlier by
  `min(deficit / 2, 45 min)`, floored at 18:00 local. Expose
  `bedtime.shifted_by_seconds`.
- **Nap-transition flag:** set `prediction.transition?: true` when either
  - weighted recent nap count is ≥ 0.75 below `Norms.typical_nap_count`, or
  - the last-window weighted median has risen > ~20 % vs the 8–14-day-ago
    weighted median.
  While true: widen every predicted range (`* 1.5` on the half-width) and let
  the dashboard say "`<name>`'s nap schedule looks like it's shifting."
- **Regime-change response (uses Phase 0 data):** if
  `PredictionLedger.accuracy/2` shows the last ~5 resolved errors are
  same-signed and each > ~25 min, halve `@recency_half_life_days` for that
  child's next predictions (via an assign passed into `predict`, not a global)
  so it re-locks faster; subtract a damped `bias_seconds` from the point
  estimate.

### Tests

- Short-nap day → earlier predicted bedtime, not below 18:00.
- Nap count 3 → 2 drift sets `transition?` and widens ranges.
- Fake a ledger with 5 × +30 min errors → next prediction shifts earlier and
  weights recency harder.

**Risk:** medium — most behavioural surface. All effects are bounded and
flagged; keep each toggle independently testable.

---

## Phase 5 — Bedtime fading (optional, has a prerequisite)

Research brief §1.7, §3.8 (second half). Needs a **"put down" vs "fell asleep"**
signal we don't capture today (`Entry.started_at` is sleep onset as logged).

1. Prereq (separate product decision): add `settled_at` (or
   `data["down_at"]`) to sleep entries + a minimal timer-UI affordance.
2. Then in `Insights`: anchor the bedtime target on the recent **sleep-onset**
   median rather than put-down; if rolling onset latency is falling
   night-over-night, walk the target ~10–15 min earlier per night toward the
   age-typical bedtime; if latency is long and rising, hold at observed onset.

Defer until Phases 0–4 are in and the prereq is agreed.

---

## End-to-end tests — ✅ DONE

`test/support/sleep_simulator.ex` — `Trygg.SleepSimulator` builds a realistic
multi-week log for a synthetic baby: an age-appropriate schedule (morning wake,
age-typical wake windows, nap count/length, bedtime) with day-to-day and
within-day Gaussian jitter, ~10 % catnaps, ~8 % rough days, and ~40 % nights
with a brief waking. Deterministic per `:seed`. `plan/4` returns the schedule
plus chronological tagged `blocks` without touching the DB, so a test replays a
day at a time — insert a block, predict at the wake — the way the real app
fills a log. `generate/4` bulk-inserts.

`test/trygg/reports/prediction_e2e_test.exs`:

- **Steady schedule** — 42 days inside the 3-nap band, replay the last 28.
  ~190 recorded predictions; asserts `next_nap` MAE < 24 min and |bias| < 10 min
  (actual ≈ 15 min / 0.5 min), the tail-20 MAE < 20 min, the most-recent third
  is no worse than the first, and ≤ 4 rows abandoned.
- **History beats the prior** — a baby whose wake windows run 40 % long; at each
  of 8 late morning wakes, compares the real history-driven prediction and a
  prior-only one against the actual nap-1 onset: history MAE < 0.7 × prior MAE.
- **Nap transition** — 56 days crossing the model's real 3→2 boundary; asserts
  `prediction.transition?` fires in the fortnight after the switch, `next_nap`
  MAE spikes that week then recovers below 32 min two weeks on, and the final
  live read is non-transition.
- **`Reports.outlook/3` end to end** — a month of history plus a partial today;
  asserts a fully populated, self-consistent prediction: `next_nap` ordinal 2 /
  `:history` or `:blended` / positive countdown / `HH:MM–HH:MM` range after
  `now`; `wake_pressure` state and `awake_seconds` correct; `bedtime` after the
  next nap with an integer `shifted_by_seconds`; the `schedule` strictly
  forward, ending on `:bed`; and the next nap within an hour of the model.

Signal change made while writing these: `transition?`'s nap-count arm is now a
recent-vs-two-weeks-ago comparison of the child's *own* count (`nap_count_dropping?`
in `insights.ex`), not "below a coarse age prior" — a baby settled on 2 naps at
7 months is no longer falsely flagged. `PredictionLedger.prediction/2` was added
(peek without recording; `track/2` reuses it).

## Cross-cutting / backlog

- **Offline prior calibration:** once the ledger has volume, aggregate
  `error_seconds` by age band across all children to retune the `Norms` anchor
  tables. A mix task / notebook, not a request-path change.
- **UI confidence:** thread a single `confidence: :low | :medium | :high`
  (from blend weight + ledger MAE + IQR) into `outlook.prediction` and let the
  dashboard render band width / wording from it, so every phase feeds one
  consistent signal instead of ad-hoc `source` checks.
- **`report_components.ex` / `reports_live.ex`** also read prediction fields —
  audit when `source`/keys change (grep `prediction`, `next_nap`, `wake_window`).
- **Docs:** update `Norms`/`Insights` moduledocs as priors and blending change;
  keep the "population guidance, not a schedule" framing.

## Suggested order & rough size

| Phase | Effort | Ships |
|---|---|---|
| 0 Ledger ✅ | M | table + worker, dark — **done** |
| 1 Continuous priors + blend ✅ | M–L | day-0 predictions, no boundary jumps — **done** |
| 2 Position + catnap ✅ | S–M | pressure-aware timing — **done** |
| 3 Clock anchoring ✅ | M | non-compounding schedule — **done** |
| 4 Sleep-balance + transitions ✅ | M | adaptive bedtime, transition signal — **done** |
| 5 Fading | S after prereq | onset-anchored bedtime — not started (needs schema prereq) |

Phases 1–4 each depend on the previous; Phase 0 is independent and should land
first so Phase 4's regime-change piece has data.
