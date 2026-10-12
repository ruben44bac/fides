# Seeds the reference data with each country's life cycle and, where a TOTP seed is
# configured, the demo staff with the first policy version of each country and the
# demo webhook receiver. Run with `mix run priv/repo/seeds.exs`; running it again
# leaves the same rows. Every write goes through an audited transaction.
Fides.Release.seed()
