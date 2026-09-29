# INTERGROWTH-21st preterm postnatal growth standards

`preterm_{weight,length}_{boys,girls}_zscores.csv` are the published
z-score tables (values at −3 … +3 SD for each exact week of postmenstrual
age, 27–64 weeks), transcribed from the University of Oxford PDFs
`grow_preterm-zs-{boys,girls}_{bw,lt}_table.pdf`. Weight is in kg, length
in cm. Used by `Trygg.Growth.PretermStandard`.

The matching centile tables live in `test/support/fixtures/intergrowth/`
and are only used to check the interpolation.

Source: Villar J, Giuliani F, Bhutta ZA, et al. Postnatal growth standards
for preterm infants: the Preterm Postnatal Follow-up Study of the
INTERGROWTH-21st Project. Lancet Glob Health 2015;3:e681–91.
Tables © University of Oxford — https://intergrowth21.com
