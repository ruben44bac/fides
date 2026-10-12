defmodule Fides.Accounts.Seeds do
  @moduledoc """
  Creates the demo staff with their scopes. Every write is audited, and running it
  again leaves the same users and scopes. The admin grants the scopes, so each one
  records who granted it.
  """

  alias Fides.Accounts.Demo
  alias Fides.Platform.AuditContext
  alias Fides.Platform.SystemActor

  @spec run() :: [Fides.Accounts.StaffUser.t()]
  def run do
    actor = SystemActor.new(:seeds)
    {[admin], others} = Enum.split_with(Demo.users(), &(&1.global_role == :admin))

    AuditContext.run([actor: SystemActor.audit_id(actor), reason: "seed demo staff"], fn ->
      admin = seed(admin, actor)
      [admin | Enum.map(others, &seed_with_scopes(&1, actor, admin))]
    end)
  end

  defp seed_with_scopes(demo, actor, admin) do
    user = seed(demo, actor)

    for {country, role} <- demo.scopes do
      Fides.Accounts.grant_scope!(user.id, role, tenant: country, actor: admin)
    end

    user
  end

  defp seed(demo, actor) do
    Fides.Accounts.seed_staff_user!(
      %{
        email: demo.email,
        global_role: demo.global_role,
        password: Demo.password(),
        totp_secret: Demo.totp_secret(demo.handle)
      },
      actor: actor
    )
  end
end
