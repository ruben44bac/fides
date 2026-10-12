defmodule Fides.Platform.Checks.InScopedCountry do
  @moduledoc """
  Policy filter check: the row belongs to a country where the actor has an active
  scope with one of `roles`. For reads that span countries: each staff user sees
  the rows of their own countries and nothing else.
  """

  use Ash.Policy.FilterCheck

  alias Fides.Platform.Actor

  @roles [:analyst, :risk_manager]

  # A typo or a missing role in a policy fails the build
  @impl true
  def init(opts) do
    roles = List.wrap(opts[:roles])

    if roles != [] and Enum.all?(roles, &(&1 in @roles)),
      do: {:ok, Keyword.put(opts, :roles, roles)},
      else: {:error, "roles must be a non-empty subset of #{inspect(@roles)}"}
  end

  @impl true
  def describe(opts), do: "row is in a country where the actor is one of #{inspect(opts[:roles])}"

  @impl true
  def filter(actor, _authorizer, opts) do
    countries = Actor.countries(actor, opts[:roles])
    expr(country_code in ^countries)
  end
end
