defprotocol Fides.Platform.Actor do
  @moduledoc """
  What policies know about whoever acts: a global role, or a role in each country.

  Platform cannot name the modules that represent actors, since every context depends
  on it, so each context implements this protocol for its own actors. Anything else,
  including no actor at all, has no role.
  """

  @fallback_to_any true

  @doc "`:admin`, `:auditor` or nil."
  @spec global_role(t()) :: :admin | :auditor | nil
  def global_role(actor)

  @doc "The role of the actor's active scope in `country`, or nil without one."
  @spec country_role(t(), String.t()) :: :analyst | :risk_manager | nil
  def country_role(actor, country)
end
