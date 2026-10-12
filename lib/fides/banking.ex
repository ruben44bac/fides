defmodule Fides.Banking do
  @moduledoc """
  Banking context: each country's bank data provider, with its own format behind an
  anti-corruption layer, so the rest of Fides only sees a normalized, masked profile.
  """

  use Fides.Platform.Domain,
    boundary: [deps: [Fides.Platform], exports: []]

  resources do
    resource Fides.Banking.BankProvider do
      define :list_bank_providers, action: :read
      define :seed_bank_provider, action: :seed
    end
  end
end
