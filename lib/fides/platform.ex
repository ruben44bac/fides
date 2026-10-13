defmodule Fides.Platform do
  @moduledoc """
  Shared infrastructure for every context: the Repo, the audit context that feeds
  Carbonite, the base modules for resources and domains, and the Spark extensions
  that enforce data classification, auditing and context isolation.

  Platform is not an Ash domain and depends on no context.
  """

  use Boundary,
    deps: [],
    exports: [
      Repo,
      Vault,
      BlindIndex,
      Types.CountryCode,
      CountryScoped,
      Mailer,
      Resource,
      Domain,
      BoundaryCompat,
      AuditContext,
      Build,
      SystemActor,
      AgentActor,
      Actor,
      Checks.SystemActor,
      Checks.Agent,
      Checks.GlobalRole,
      Checks.ScopedRole,
      Checks.InScopedCountry,
      Context,
      DataInventory,
      Classification,
      Classification.Info,
      Audited,
      Audited.Info,
      ContextIsolation
    ]
end
