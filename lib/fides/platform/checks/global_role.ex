defmodule Fides.Platform.Checks.GlobalRole do
  @moduledoc "Policy check: the actor's global role is one of `roles`."

  use Ash.Policy.SimpleCheck

  alias Fides.Platform.Actor

  @roles [:admin, :auditor]

  # A typo or a missing role in a policy fails the build
  @impl true
  def init(opts) do
    roles = List.wrap(opts[:roles])

    if roles != [] and Enum.all?(roles, &(&1 in @roles)),
      do: {:ok, Keyword.put(opts, :roles, roles)},
      else: {:error, "roles must be a non-empty subset of #{inspect(@roles)}"}
  end

  @impl true
  def describe(opts), do: "actor's global role is one of #{inspect(opts[:roles])}"

  @impl true
  def match?(actor, _context, opts), do: Actor.global_role(actor) in opts[:roles]
end
