defmodule Fides.Countries.SensitiveProbe do
  @moduledoc "Test resource that shows how classification drives `sensitive?`."

  use Fides.Platform.Resource,
    domain: Fides.Countries.TestDomain,
    data_layer: Ash.DataLayer.Ets

  attributes do
    uuid_v7_primary_key :id
    attribute :email, :string
    attribute :amount_minor, :integer
  end

  classification do
    attribute :id, :pseudonymous
    attribute :email, :pii
    attribute :amount_minor, :financial
  end
end
