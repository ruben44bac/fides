# Seeds the reference data with each country's life cycle and, in development, the
# demo staff with the first policy version of each country. Run with
# `mix run priv/repo/seeds.exs`; running it again leaves the same rows. Every write
# goes through an audited transaction.
Fides.Countries.Seeds.run()
Fides.Identity.Seeds.run()
Fides.Banking.Seeds.run()
Fides.Origination.Seeds.run()

if Fides.Accounts.Demo.enabled?() do
  staff = Fides.Accounts.Seeds.run()
  Fides.Risk.Seeds.run(staff["risk_manager_1"], staff["risk_manager_2"])
end
