# Infant sleep prediction — research brief

Background reading for improving the nap / bedtime prediction in
`Trygg.Reports.Insights` and its age priors in `Trygg.Reports.Norms`.

Goal restated: predictions should be **accurate**, should **update continuously**
as new sleep is logged, and should **get better over the weeks** as the child's
own pattern accumulates.

The current engine is already reasonable — median + IQR per nap ordinal over a
14‑day window, age‑band priors as a labelled fallback, a fresh/approaching/past
wake‑pressure state machine, and a projected rest‑of‑day schedule. This brief
records what the current evidence says the numbers *should* be, where the app
diverges, and a concrete list of algorithm changes.

---

## 1. What the evidence actually supports

### 1.1 Total sleep per 24 h

| Age | Consensus recommendation | Observed mean (range ≈ ±2 SD) |
|---|---|---|
| 0–3 mo | 14–17 h (NSF; AASM "no rec" but endorses NSF direction) | newborn ≈ 16 h (CHOP: ~8–9 h day + ~8 h night) |
| 4–12 mo | 12–16 h incl. naps (NSF / AASM consensus) | infants <2 y: **12.8 h/day, 9.7–15.9** (Galland 2012 meta, 69,542 infants, 18 countries) |
| 1–2 y | 11–14 h incl. naps | toddler/preschool: 11.9 h/day, 9.9–13.8 |

Longitudinal reference curves (Iglowstein 2003, Zurich cohort, still the most
cited): ~14.5 h at 1 mo → ~14 h at 6 mo → ~13.9 h at 12 mo → ~13 h at 2 y, with
wide and *stable-per-child* individual differences and a documented generational
downward drift.

**Takeaway for us:** total‑sleep norms are only useful as a very wide sanity
band. Inter‑individual spread (~6 h wide at any age) dwarfs the age trend, so the
child's own rolling total should dominate almost immediately.

### 1.2 Day vs. night split and circadian onset

- Circadian (day/night) organisation is **not established until ~3–4 months**;
  "consistent diurnal sleep and wake patterns typically develop between 3 and 6
  months" (Frontiers 2025 mini‑scoping review; Armstrong 1994).
- Total **nocturnal** sleep: ≈ 7–8 h at 4 weeks → rises steadily to ~15–20 weeks
  → ≈ 9.5 h (study range 8–11 h) by 24 weeks (Frontiers 2025 review).
- Across year 1, **daytime** sleep falls and **night** sleep rises slightly
  (systematic review: night 11.0 ± 1.1 h at 1 mo → 11.7 ± 1.0 h at 1 y; KellyMom
  study compilation).

**Takeaway:** before ~12–16 weeks, "next nap" and "bedtime" are barely
meaningful — the app should lean hard on the age prior, widen its ranges, and say
so. After ~4 months the child's own clock times become the strong anchor.

### 1.3 Longest continuous sleep / "sleeping through the night"

- Longest sleep stretch ≈ 2.5 h at week 10 → 4 h (actigraphy) / 6.5 h (diary) by
  week 24 (Frontiers 2025 review).
- Night waking stays **normal and common all year**: waking at least once —
  ~46 % at 3 mo, 39 % at 6 mo, 58 % at 9 mo, 55 % at 12 mo (Scher 1991); at 6 mo
  only ~16 % "sleep through" (Sadler 1994); average night‑waking frequency ~77 %
  of infants (Wooding 1990). A 9‑month bump is real (developmental / separation).
- Measurement method changes the number a lot — actigraphy always reports *more*
  wakings than parent diaries.

**Takeaway:** the product decision that SweetSpot/predictions **exclude night
wakings** (assume baby resettles) is evidence‑aligned and should stay. Do not try
to predict night‑waking times. Do consider surfacing "night wakings are normal at
this age" copy around the 8–10 month mark so the prediction gap doesn't read as a
bug.

### 1.4 Wake windows — the load‑bearing input, and the weakest evidence

**There is no peer‑reviewed wake‑window table.** Every published chart
(Huckleberry, The Bump, Taking Cara Babies, Baby Sleep Science…) is practitioner
consensus derived from client data, not studies. They agree on shape, disagree on
±20–30 min at the edges. Composite of the mainstream charts:

| Age | Typical wake window (awake time between sleeps) |
|---|---|
| 0–8 wk (newborn) | 30–90 min (often only 45–60) |
| 3 mo | 60–120 min |
| 4–5 mo | 90–150 min |
| 6 mo | 120–180 min |
| 7–8 mo | 150–210 min |
| 9 mo | 150–210 min |
| 10–12 mo | 180–240 min |
| 12–15 mo (2 naps) | 180–270 min |
| 15–18 mo → 1 nap | ~5–6 h before the nap, ~5–6 h after (see §1.5) |
| 2–3 y (1 nap) | ~5–6 h morning, ~4–5 h after nap |

Two structural facts every chart notes but a single range hides:

1. **Wake windows are asymmetric across the day.** The first window after morning
   wake is the *shortest*; the last window before bed is the *longest*, commonly
   30–60 min beyond the midday windows. Our per‑ordinal medians learn this from
   data, but the age *prior* collapses it to one number.
2. **The just‑finished sleep changes the next window.** A 30–45 min "catnap"
   (one sleep cycle) leaves much more sleep pressure than a 90–120 min nap, so
   the following wake window is shorter. Nothing in the model uses nap *duration*
   as an input to the next wake window.

### 1.5 Nap count and nap transitions

| Age | Naps/day | Notes |
|---|---|---|
| 0–10 wk | 4–5 | irregular, no clock structure |
| 3–4 mo | 3–4 | "4th catnap" fades ~4 mo |
| 4–6 mo | 3 | |
| 6–8 mo | 3 → 2 | most complete the 3→2 drop by ~8 mo |
| 9–15 mo | 2 | |
| ~14–18 mo (mode 15 mo) | 2 → 1 | readiness > age; 2–6 wk transition, temporary early bedtime |
| 15 mo – ~3 y | 1 | midday, ~1.5–3 h |
| 3–5 y | 1 → 0 | |

### 1.6 Sleep‑cycle length (prediction resolution)

Infant ultradian cycle ≈ 40–50 min in the early months (vs ~90 min adult) and
**lengthens across the first year** toward ~55–60 min (Hammad et al. 2025,
*Sleep* — 35,000 h of longitudinal ankle actigraphy; direction is robust even
though exact monthly values sit behind the paywall).

**Takeaway:** a nap ending near a single cycle multiple (~35–50 min early, ~50–60
min later) is a "partial" nap; treat the following wake window as reduced. Don't
predict nap *durations* more precisely than ~1 cycle.

### 1.7 Bedtime

- A consistent **bedtime routine** independently predicts shorter sleep‑onset
  latency, less wake‑after‑sleep‑onset, longer night sleep, and better
  consolidation (Mindell; 2025 ScienceDirect review "Optimizing infant and
  toddler sleep"). This is the strongest *interventional* evidence in the whole
  area and directly supports the "wind‑down heads‑up" notification.
- Bedtime clock time is fairly stable per child from ~4 mo (7:00–8:00 pm
  typical), and pulls **earlier** (down to ~6:00–6:30 pm) after short naps,
  missed naps, or during a nap transition.
- **Bedtime fading** is a validated behavioural technique that is really an
  algorithm: set bedtime at the child's *observed* natural sleep‑onset time
  (when they actually fall asleep, not when they're put down), then move it
  earlier in ~15‑min steps on successive nights as sleep‑onset latency drops.
  It raises sleep pressure, cuts bedtime resistance and shortens time‑to‑sleep.
  We already have the raw signal for this — logged "put down" vs. sleep start —
  so the predictor can *compute* a faded‑bedtime target rather than just
  echoing the clock median (see §3.8).

### 1.8 Self‑regulation: signalling vs. self‑settling

An infant's capacity to **self‑regulate sleep** — settle quickly and resettle
after a night waking without parental intervention — is a first‑year
developmental milestone (Henderson, Blampied & France 2020). It matters for
*prediction quality*, not just for sleep‑training guidance:

- For a **self‑settling** child, sleep‑onset time is largely endogenous, so
  `last_wake + wake_window` tracks well and the child's own medians are tight.
- For a **signalling** child, logged sleep start reflects *when a caregiver
  intervened*, which is noisier and caregiver‑dependent — wider IQRs, more
  predicted‑vs‑actual error. The self‑evaluation loop (§3.9) will surface this
  automatically as a higher rolling MAE; the honest response is a wider band,
  not a falsely precise time.
- Infants who habitually signal are at higher risk of *persistent* sleep
  problems into toddlerhood (Gaylor et al. 2005), so a sustained pattern of
  short, intervention‑dependent sleeps is worth detecting — but as gentle,
  optional context, not a diagnosis.

**Scope note:** behavioural interventions themselves (graduated extinction,
unmodified extinction, bedtime fading as a *training programme*) are evidence‑
based and carry no demonstrated harm to attachment or development at 18 months
(Bilgin & Wolke 2020), and are typically recommended from ~6 months. Whether
Trygg ever *coaches* sleep training is a separate product decision from timing
prediction. The only piece this brief pulls in is bedtime fading's arithmetic
(§3.8), because we can do it silently inside an existing prediction.

---

## 2. Where the app currently diverges

`Trygg.Reports.Norms.wake_window_range/1` vs. the §1.4 composite:

| Age band (code) | Code (min) | Composite | Verdict |
|---|---|---|---|
| < 28 d | 45–60 | 30–90 | top is low; floor could drop to ~35 |
| < 90 d | 60–90 | 60–120 | **top too low** — 3 mo reaches ~2 h |
| < 150 d | 75–120 | 90–150 | slightly low |
| < 210 d | 120–180 | 120–180 | ok |
| < 300 d | 150–210 | 150–210 | ok |
| < 390 d | 180–240 | 180–240 | ok |
| < 570 d | 180–270 | 2‑nap 180–270 **or** 1‑nap ~300–360 | ambiguous across the 2→1 transition |
| < 730 d | 240–360 | 300–360 | ok |
| < 1095 d | 300–360 | 300–360 | ok |

Other gaps:

1. **Step discontinuities.** The prior jumps at 90 / 150 / 210 … days. A child
   logged the day before and after a boundary sees the prediction lurch. Prior
   should interpolate continuously in age.
2. **No nap‑count prior.** `typical_nap_count/1` reads the child's own median and
   returns `0` when there's no history — so `next_nap_prediction` returns `nil`
   for the first 3 logged days. A day‑0 child gets *no* nap prediction. Needs
   `Norms.typical_nap_count(age_days)`.
3. **Prior is position‑blind.** Same range for the first and last window of the
   day (see §1.4 fact 1).
4. **Nap duration is unused.** `next_nap_prediction` = `last_wake +
   wake_window`; the length of the nap that just ended doesn't shorten or
   lengthen the next window (§1.4 fact 2, §1.6).
5. **Hard `ready?` switch at `@min_sample = 3`.** Below 3 sleep‑days →
   pure prior; at 3 → pure history. No smooth blend, no down‑weighting of a
   12‑day‑old day vs. yesterday.
6. **Errors compound across the day.** Each nap is predicted as previous end +
   window; a 20‑min miss on nap 1 shifts naps 2, 3 and bedtime. Only
   `bedtime_prediction` blends in an absolute clock‑median.
7. **No self‑evaluation.** Nothing records "predicted 14:20 / actual 14:45", so
   the engine can't measure its own error, can't widen the band when it's been
   wrong, and can't tell the user how confident it is.
8. **Bedtime ignores nap debt.** If the day's logged sleep is running short,
   evidence says bring bedtime *earlier*; the current prediction is
   clock‑median + last window only.

---

## 3. Recommended algorithm changes

Ordered roughly by expected accuracy gain per unit of work.

### 3.1 Continuous prior→history blend (shrinkage), not a switch
Replace the `ready?` boolean with a weight `w = n_eff / (n_eff + k)` (start
`k ≈ 3`). Predicted window = `w · history_median + (1 − w) · prior_mid`. `n_eff`
is the *effective* sample size after recency weighting (3.2). Removes the day‑3
cliff and makes every logged sleep nudge the number.

### 3.2 Recency weighting with a half‑life
Weight each past day by `0.5 ^ (age_in_days / H)`, `H ≈ 5–7 days` (matches both
the "last five days" idea in the SweetSpot description and the pace of real
change at this age). Drop the hard 14‑day cut, or keep it only as a cheap
pre‑filter at ~21 days. Apply the same weights to medians (weighted median) and
to `n_eff = Σ w`.

### 3.3 Continuous age prior
Rewrite `Norms.wake_window_range/1` (and the new nap‑count prior) as
interpolation between anchor points rather than `cond` bands. Anchors for the
midday window, in minutes:

```
 3 wk  40–65      6 mo  120–170
 6 wk  45–80      8 mo  140–195
10 wk  55–95     10 mo  155–210
14 wk  65–110    12 mo  170–235
 4 mo  85–135    15 mo  (1 nap — see 3.4)
 5 mo 100–150    18 mo  morning 270–350 / afternoon 240–320
```

Linear interpolation in `age_days` between anchors; clamp outside the range.

### 3.4 Position‑aware windows
Prior window for nap ordinal `i` of an expected `N` = `midday_prior ·
position_factor(i, N)`, roughly `first ≈ 0.80–0.85`, `middle ≈ 1.0`,
`last‑before‑bed ≈ 1.15–1.25`. The history path already learns this via
`by_ordinal`; apply the factor only to the prior component so thin‑history
children still get the shape.

### 3.5 Sleep‑pressure feedback from the last nap
Shorten the next wake window when the nap that just ended was short:
`adj = clamp(nap_len / typical_nap_len_for_ordinal, 0.7, 1.15)`, multiply the
predicted window by `adj`. A 35‑min catnap ⇒ ~0.7× ⇒ next nap sooner. Also apply
a gentle floor by age (never predict a newborn window < 30 min).

### 3.6 Nap‑count prior + transition awareness
Add `Norms.typical_nap_count(age_days)` (§1.5 table). Use `round(w · history +
(1 − w) · prior)`. When recent nap count is drifting **below** the age‑typical
value, or the last‑window medians are climbing week‑over‑week, mark
`transition?: true`, widen all bands for the day (e.g. ×1.5 IQR), and let the UI
say "nap schedule looks like it's changing".

### 3.7 Anchor later predictions to clock time, not just cumulative windows
Generalise what `bedtime_prediction` already does: for every nap ordinal with a
stable historical clock median, predict `blend(from_wake_cumulative,
clock_median, β(i))` where `β` shifts toward the absolute clock as `i` grows
(nap 1 ≈ 0.2 clock, bedtime ≈ 0.6 clock). Stops a single early miss from
dragging the whole day. Morning wake time is the primary circadian anchor —
weight it heavily and never let a predicted time precede it.

### 3.8 Bedtime responds to the day's sleep balance, with fading arithmetic
If `day_sleep_so_far + expected_remaining_naps` is below the child's rolling
day‑sleep median by more than ~30 min, pull predicted bedtime earlier by up to
~30–45 min (evidence: earlier bedtime compensates short/missed naps). Cap the
shift; never earlier than ~6:00 pm local.

Layer bedtime fading on top when we have put‑down vs. sleep‑start data: anchor
the predicted bedtime on the child's recent **sleep‑onset** median rather than
the put‑down median, and if their rolling sleep‑onset latency is falling
night‑over‑night, walk the target ~10–15 min earlier per night toward the
age‑typical bedtime. If latency is long and rising, hold the target at observed
onset instead of predicting an earlier time the child won't take.

### 3.9 Self‑evaluation loop (the "gets better over time" part)
Persist each prediction and its realised outcome:

```
sleep_predictions(child_id, kind, predicted_at, predicted_for,
                  target_ts, range_lo_ts, range_hi_ts, source,
                  actual_ts, error_seconds, inserted_at)
```

On each new sleep log, close out the matching open prediction (`kind = :next_nap
| :bedtime`), write `actual_ts` and `error_seconds`. Then:

- **Rolling MAE per child per kind** → drives the *width* of the range shown to
  the user (band ≈ `max(child_IQR, 1.3 · MAE)`), so confidence is honest.
- **Bias term** → if predictions run consistently ~12 min late, subtract a
  damped rolling mean error from the point estimate.
- **Prior calibration** → aggregate `error_seconds` by age band across *all*
  children to tune the anchor tables over time (offline, not per‑request).
- **Regime‑change detector** → a run of same‑signed large errors ⇒ shrink the
  effective history window (raise the 3.2 weights' recency) so the model
  re‑locks onto the new pattern faster.

### 3.10 Keep the floors
`Norms` stays the sanity clamp its moduledoc already describes: min newborn
window 30 min, max 5 naps, bedtime window 6:00 pm–9:30 pm, night‑waking
prediction stays out of scope.

---

## 4. Suggested build order

1. `sleep_predictions` table + record/close‑out on log write, MAE/bias surfaced
   in the existing range (3.9) — no behaviour change, starts collecting ground
   truth immediately.
2. Continuous prior + `typical_nap_count/1` + shrinkage blend (3.1–3.3, 3.6) —
   fixes day‑0 and the boundary lurches.
3. Position factor + catnap feedback (3.4–3.5).
4. Clock anchoring + bedtime sleep‑balance (3.7–3.8).
5. Transition detection + regime‑change response (3.6 tail, 3.9 tail).

Each step is independently shippable and testable against
`test/trygg/reports/insights_test.exs`.

---

## Sources

- National Sleep Foundation / AASM consensus on sleep duration for children —
  <https://www.paaap.org/uploads/1/2/4/3/124369935/551b74_0a25804f79b44994bb8db7ed9ed957db.pdf>,
  <https://pmc.ncbi.nlm.nih.gov/articles/PMC5078711/>,
  <https://aasm.org/advocacy/position-statements/child-sleep-duration-health-advisory/>
- Galland et al. 2012, *Normal sleep patterns in infants and children: a
  systematic review of observational studies* —
  <https://www.sciencedirect.com/science/article/abs/pii/S1087079211000682>
- Iglowstein et al. 2003, *Sleep Duration From Infancy to Adolescence: Reference
  Values and Generational Trends*, Pediatrics —
  <https://publications.aap.org/pediatrics/article/111/2/302/66745/Sleep-Duration-From-Infancy-to-Adolescence>
- CHOP, *Newborn Sleep Patterns* —
  <https://www.chop.edu/pages/newborn-sleep-patterns>
- KellyMom, *Studies on normal infant sleep* (Scher 1991, Sadler 1994, Wooding
  1990, Armstrong 1994, Goodlin‑Jones 2001) —
  <https://kellymom.com/parenting/nighttime/sleepstudies/>
- Frontiers in Neuroscience 2025, *Maturation of infant sleep during the first 6
  months of life: a mini‑scoping review* —
  <https://www.frontiersin.org/journals/neuroscience/articles/10.3389/fnins.2025.1581325/full>
- Henderson et al. 2010, *Sleeping Through the Night: The Consolidation of
  Self‑regulated Sleep Across the First Year of Life*, Pediatrics —
  <https://publications.aap.org/pediatrics/article/126/5/e1081/65212/>
- Hammad et al. 2025, *Charting infant sleep cycle development using actigraphy*
  (35,000 h longitudinal) — <https://doi.org/10.1093/sleep/zsag161>,
  preprint <https://www.biorxiv.org/content/10.1101/2025.07.10.664225>
- 2025 review, *Optimizing infant and toddler sleep: evidence‑based approaches
  to promote sleep consolidation* —
  <https://www.sciencedirect.com/science/article/abs/pii/S1526054225001083>
- *Sleep and infant development in the first year*, Pediatric Research 2026
  (paywalled) — <https://www.nature.com/articles/s41390-026-04780-4>
- Henderson, Blampied & France 2020, *Longitudinal Study of Infant Sleep
  Development: Early Predictors of Sleep Regulation Across the First Year*,
  Nature and Science of Sleep 12, 949–957 —
  <https://doi.org/10.2147/nss.s240075>
- Bilgin & Wolke 2020, *Parental use of 'cry it out' in infants: no adverse
  effects on attachment and behavioural development at 18 months*, JCPP 61,
  1184–1193 — <https://doi.org/10.1111/jcpp.13223>
- Gaylor, Burnham, Goodlin‑Jones & Anders 2005, *A Longitudinal Follow‑Up Study
  of Young Children's Sleep Patterns Using a Developmental Classification
  System*, Behavioral Sleep Medicine 3, 44–61 —
  <https://doi.org/10.1207/s15402010bsm0301_6>
- Wake‑window / nap‑transition practitioner charts: Huckleberry
  <https://huckleberrycare.com/blog/first-year-of-sleep-expectations>,
  <https://huckleberrycare.com/blog/2-to-1-nap-transition>; The Bump
  <https://www.thebump.com/a/wake-windows>
