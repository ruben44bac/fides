# Seeds the reference data and, in development, the demo staff. Run with
# `mix run priv/repo/seeds.exs`; running it again leaves the same rows. Every write
# goes through an audited transaction.
Fides.Countries.Seeds.run()
Fides.Identity.Seeds.run()
Fides.Banking.Seeds.run()

if Fides.Accounts.Demo.enabled?(), do: Fides.Accounts.Seeds.run()
