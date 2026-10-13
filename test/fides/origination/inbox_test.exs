defmodule Fides.Origination.InboxTest do
  # Seeds the same countries as other tests: running alone avoids waiting on their locks
  use Fides.DataCase, async: false

  alias Fides.Factory
  alias Fides.Origination

  setup do
    Factory.reference_data()
    {admin, _secret} = Factory.staff_user(global_role: :admin)
    analyst = Factory.scoped_staff("ES", :analyst, admin)
    mexican = Factory.scoped_staff("MX", :analyst, admin)

    spanish =
      for amount <- [100_000, 200_000, 300_000] do
        Factory.insert(fn ->
          Origination.submit_application!(Factory.submission(amount_minor: amount),
            tenant: "ES",
            actor: analyst
          )
        end)
      end

    foreign =
      Factory.insert(fn ->
        Origination.submit_application!(Factory.mexican_submission(),
          tenant: "MX",
          actor: mexican
        )
      end)

    %{admin: admin, analyst: analyst, spanish: spanish, foreign: foreign}
  end

  defp ids(page), do: Enum.map(page.results, & &1.id)

  test "an analyst gets their countries' applications, newest first; an admin gets every country's",
       ctx do
    [oldest, middle, newest] = ctx.spanish

    {:ok, page} = Origination.inbox(%{}, actor: ctx.analyst)
    assert ids(page) == [newest.id, middle.id, oldest.id]
    refute page.more?

    {:ok, page} = Origination.inbox(%{}, actor: ctx.admin)
    assert ctx.foreign.id in ids(page)
    assert length(page.results) == 4
  end

  test "narrows by country and state, and pages with a cursor", ctx do
    [oldest, middle, newest] = ctx.spanish

    {:ok, page} = Origination.inbox(%{country: "MX"}, actor: ctx.admin)
    assert ids(page) == [ctx.foreign.id]

    {:ok, page} = Origination.inbox(%{state: :approved}, actor: ctx.admin)
    assert page.results == []

    {:ok, first} = Origination.inbox(%{country: "ES", limit: 2}, actor: ctx.analyst)
    assert ids(first) == [newest.id, middle.id]
    assert first.more?

    cursor = Ash.Resource.get_metadata(List.last(first.results), :keyset)

    {:ok, second} =
      Origination.inbox(%{country: "ES", limit: 2, after: cursor}, actor: ctx.analyst)

    assert ids(second) == [oldest.id]
    refute second.more?
  end
end
