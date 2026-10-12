defmodule Fides.Risk.SeedsTest do
  # Seeds the same countries as other tests: running alone avoids waiting on their locks
  use Fides.DataCase, async: false

  alias Fides.Risk

  setup do
    Fides.Factory.countries()
    staff = Fides.Accounts.Seeds.run()
    %{proposer: staff["risk_manager_1"], approver: staff["risk_manager_2"], admin: staff["admin"]}
  end

  test "every country gets its first version in force, approved by a second risk manager", ctx do
    first = Risk.Seeds.run(ctx.proposer, ctx.approver)

    assert length(first) == length(Risk.Engine.countries())
    assert Risk.Seeds.run(ctx.proposer, ctx.approver) == []

    for country <- Risk.Engine.countries() do
      version = Risk.policy_in_force!(tenant: country, actor: ctx.admin)
      {:ok, defaults} = Risk.default_params(country)

      assert %{version: 1, status: :published} = version
      assert {version.proposed_by, version.approved_by} == {ctx.proposer.id, ctx.approver.id}
      assert Risk.cast_params(country, version.params) == {:ok, defaults}
    end
  end
end
