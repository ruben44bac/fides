defmodule Fides.Accounts.Secrets do
  @moduledoc """
  The secret that signs each resource's tokens, read from the configuration on every
  use. Each resource has its own, so a token signed for one never verifies for
  another.
  """

  use AshAuthentication.Secret

  @impl true
  def secret_for([:authentication, :tokens, :signing_secret], resource, _opts, _context) do
    with {:ok, config} <- Application.fetch_env(:fides, resource) do
      Keyword.fetch(config, :token_signing_secret)
    end
  end
end
