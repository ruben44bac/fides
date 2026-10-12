defmodule Fides.Accounts.SeedsTest do
  # Seeds the same countries as other tests: running alone avoids waiting on their locks
  use Fides.DataCase, async: false

  alias Fides.Accounts
  alias Fides.Accounts.Demo
  alias Fides.Accounts.Seeds

  setup do
    Fides.Factory.countries()
    :ok
  end

  test "the demo staff exist once, with the scopes the admin granted them" do
    first = Seeds.run()
    again = Seeds.run()

    assert Enum.map(again, & &1.id) == Enum.map(first, & &1.id)
    assert length(first) == length(Demo.users())

    [admin | _others] = first
    assert admin.global_role == :admin

    scopes = Accounts.list_all_scopes!(actor: admin)
    assert length(scopes) == Enum.sum_by(Demo.users(), &length(&1.scopes))
    assert Enum.all?(scopes, &(&1.granted_by == admin.id))
  end

  @tag spec: "API-01"
  test "every demo staff user signs in with the shared password and their own code" do
    Seeds.run()

    for %{handle: handle, email: email} <- Demo.users() do
      assert {:ok, _token, _claims} =
               Accounts.sign_in(email, Demo.password(), Demo.totp_code(handle)),
             handle
    end
  end

  test "demo staff are found by handle where a TOTP seed is configured" do
    assert Demo.enabled?()
    assert "analyst_mx" in Demo.handles()
    assert Demo.user("nobody") == nil
  end
end
