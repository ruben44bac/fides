# Seeds the reference data and, where a TOTP seed is configured, the demo staff with
# the first policy version of each country. Run with `mix run priv/repo/seeds.exs`;
# running it again leaves the same rows. Every write goes through an audited transaction.
Fides.Release.seed()
