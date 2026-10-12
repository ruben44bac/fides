defmodule Fides.Accounts.StaffUserTest do
  use Fides.DataCase, async: true

  alias Fides.Accounts
  alias Fides.Accounts.StaffScope
  alias Fides.Accounts.StaffUser
  alias Fides.Factory
  alias Fides.Platform.Checks.ScopedRole

  setup do
    {admin, _secret} = Factory.staff_user(global_role: :admin)
    {auditor, _secret} = Factory.staff_user(global_role: :auditor)
    {analyst, _secret} = Factory.staff_user()

    %{admin: admin, auditor: auditor, analyst: analyst}
  end

  test "staff read only themselves, while admins and auditors read anyone", ctx do
    assert [%{id: id}] = Ash.read!(StaffUser, actor: ctx.analyst)
    assert id == ctx.analyst.id

    assert {:error, %Ash.Error.Invalid{}} =
             Accounts.get_staff_user(ctx.admin.id, actor: ctx.analyst)

    for actor <- [ctx.admin, ctx.auditor] do
      assert {:ok, _user} = Accounts.get_staff_user(ctx.analyst.id, actor: actor)
    end
  end

  test "only the system seeds staff or records their sign-ins", ctx do
    attrs = %{
      email: "new@fides.test",
      password: Factory.staff_password(),
      totp_secret: NimbleTOTP.secret()
    }

    assert {:error, %Ash.Error.Forbidden{}} = Accounts.seed_staff_user(attrs, actor: ctx.admin)

    for {action, args} <- [
          claim_totp_step: %{step_start: DateTime.utc_now()},
          record_failed_sign_in: %{wrong_code?: true}
        ] do
      assert {:error, %Ash.Error.Forbidden{}} =
               ctx.analyst
               |> Ash.Changeset.for_update(action, args, actor: ctx.admin)
               |> Ash.update()
    end
  end

  test "a scope authorizes only in its own country and with its own role" do
    actor = %StaffUser{
      global_role: nil,
      active_scopes: [%StaffScope{country_code: "MX", role: :analyst}]
    }

    assert ScopedRole.match?(actor, %{subject: %{to_tenant: "MX"}}, roles: [:analyst])
    refute ScopedRole.match?(actor, %{subject: %{to_tenant: "MX"}}, roles: [:risk_manager])
    refute ScopedRole.match?(actor, %{subject: %{to_tenant: "CO"}}, roles: [:analyst])
    refute ScopedRole.match?(actor, %{subject: %{to_tenant: nil}}, roles: [:analyst])
    refute ScopedRole.match?(actor, %{}, roles: [:analyst])
  end
end
