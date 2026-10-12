defmodule Fides.Platform.Checks.ScopedRole do
  @moduledoc """
  Policy check: the actor has an active scope with one of `roles` in the request's
  country, which is its tenant. Without a tenant the check is false.

  It never reads the data, so it only protects actions where Ash limits the rows to
  the tenant: reads, updates and destroys of a per-country resource, which Ash
  filters by the tenant, and creates, where Ash sets it. Actions that bypass
  multitenancy and generic actions have a tenant but no such limit, so they need
  other checks.
  """

  use Ash.Policy.SimpleCheck

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
  def describe(opts),
    do: "actor has an active scope in the tenant's country as one of #{inspect(opts[:roles])}"

  # The subject is the query, changeset or action input; to_tenant is its tenant
  @impl true
  def match?(actor, %{subject: %{to_tenant: country}}, opts) when is_binary(country),
    do: Actor.country_role(actor, country) in opts[:roles]

  def match?(_actor, _context, _opts), do: false
end
