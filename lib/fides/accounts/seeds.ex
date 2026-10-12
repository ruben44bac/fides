defmodule Fides.Accounts.Seeds do
  @moduledoc """
  Creates the demo staff with their scopes. Every write is audited, and running it
  again leaves the same users and scopes. The admin grants the scopes, so each one
  records who granted it.
  """

  alias Fides.Accounts.Demo
  alias Fides.Platform.AuditContext
  alias Fides.Platform.SystemActor

  @doc "The demo staff by handle, with the scopes that authorize them."
  @spec run() :: %{String.t() => Fides.Accounts.StaffUser.t()}
  def run do
    actor = SystemActor.new(:seeds)
    {[admin], others} = Enum.split_with(Demo.users(), &(&1.global_role == :admin))

    AuditContext.run([actor: SystemActor.audit_id(actor), reason: "seed demo staff"], fn ->
      admin_user = seed(admin, actor)

      others
      |> Map.new(&{&1.handle, seed_with_scopes(&1, actor, admin_user)})
      |> Map.put(admin.handle, admin_user)
      |> Map.new(fn {handle, user} -> {handle, Fides.Accounts.load_actor(user)} end)
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
