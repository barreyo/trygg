# Sleep-prediction UI — screenshots

New copy wired in by the "Wire the new sleep-prediction signals into the UI"
change. Captured from a seeded dev instance (dark theme).

## Home — thin history reads "still learning the pattern"

A child with only a few days of nap history: the estimate leans on their own
pattern but isn't settled yet, so the next-nap line ends with
`· still learning the pattern`.

![Home card: Next nap ≈ 09:09 (08:25–09:15) · in 46m · still learning the pattern](dashboard-still-learning.png)

## Home — a nap-count drop flags the shift

A child whose recent nap count has dropped versus two weeks ago: the sleep card
status reads `nap schedule looks like it's shifting` and the next-nap line ends
with `· schedule may be shifting`.

![Home card: sleep status "nap schedule looks like it's shifting", next nap line "· schedule may be shifting"](dashboard-transition.png)

## Reports outlook — transition note, earlier bedtime, recent accuracy

The Reports "Today's outlook" card, showing all three new lines at once: the
transition note, a bedtime pulled `earlier tonight, naps ran short`, and
`Recent nap predictions landed within about 9 min` from the reconciled
prediction ledger.

![Reports outlook card with the transition note, "Bedtime ≈ 18:45 · earlier tonight, naps ran short", and "Recent nap predictions landed within about 9 min"](reports-outlook.png)
