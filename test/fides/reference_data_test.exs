defmodule Fides.ReferenceDataTest do
  # Seeds the same countries as other tests: running alone avoids waiting on their locks
  use Fides.DataCase, async: false

  alias Fides.Platform.SystemActor

  @tag spec: "CTRY-02"
  test "every active country has document types, a bank provider, a policy and a life cycle" do
    Fides.Factory.reference_data()

    for %{code: country, status: :active} <- Fides.Countries.list_countries!() do
      assert Fides.Identity.list_document_types!(tenant: country) != [], country
      assert [_provider] = Fides.Banking.list_bank_providers!(tenant: country), country
      assert {:ok, %{countersign_above_minor: _}} = Fides.Risk.default_params(country)

      assert Fides.Origination.available_transitions(country, :submitted, :system) == [
               :validating
             ]
    end
  end

  test "seeding twice leaves the same reference data" do
    Fides.Factory.reference_data()
    first = snapshot()

    Fides.Factory.reference_data()
    assert snapshot() == first
  end

  test "Mexico's bank provider answers asynchronously" do
    Fides.Factory.reference_data()

    assert [%{mode: :async, adapter: "mx_webhook"}] =
             Fides.Banking.list_bank_providers!(tenant: "MX", actor: SystemActor.new(:test))
  end

  defp snapshot do
    for %{code: country} <- Fides.Countries.list_countries!() do
      {country, Enum.map(Fides.Identity.list_document_types!(tenant: country), & &1.code),
       Enum.map(Fides.Banking.list_bank_providers!(tenant: country), &{&1.id, &1.mode})}
    end
  end
end
