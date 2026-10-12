defmodule Fides.Accounts.StaffScopeTest do
  # Seeds the same countries as other tests: running alone avoids waiting on their locks
  use Fides.DataCase, async: false

  alias Fides.Accounts
  alias Fides.Accounts.StaffScope
  alias Fides.Accounts.StaffUser
  alias Fides.Factory
  alias Fides.Platform.Actor
  alias Fides.Platform.AuditContext

  setup do
    Factory.countries()
    {admin, _secret} = Factory.staff_user(global_role: :admin)
    {auditor, _secret} = Factory.staff_user(global_role: :auditor)
    {analyst, _secret} = Factory.staff_user()
    Factory.scope(analyst, "MX", :analyst, admin)
    AuditContext.put(actor: "staff_user:" <> admin.id, reason: "manage scopes")

    %{admin: admin, auditor: auditor, analyst: analyst}
  end

  # The actor as a request sees it: loaded from its token's subject
  defp as_actor(user, opts \\ []) do
    {:ok, actor} =
      AshAuthentication.subject_to_user(AshAuthentication.user_to_subject(user), StaffUser, opts)

    actor
  end

  defp scopes(user), do: Enum.map(as_actor(user).active_scopes, &{&1.country_code, &1.role})

  describe "granting and revoking" do
    @tag spec: "ACCT-10"
    test "only the admin grants or revokes, and each scope records who did", ctx do
      # Refused before anything is said about the grantee, whoever it is
      for actor <- [ctx.auditor, as_actor(ctx.analyst), nil],
          grantee <- [ctx.analyst.id, ctx.admin.id, ctx.auditor.id, Ash.UUIDv7.generate()] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Accounts.grant_scope(grantee, :analyst, tenant: "CO", actor: actor)
      end

      assert {:ok, scope} =
               Accounts.grant_scope(ctx.analyst.id, :analyst, tenant: "CO", actor: ctx.admin)

      assert scope.granted_by == ctx.admin.id

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.revoke_scope(scope, tenant: "CO", actor: ctx.auditor)

      assert {:ok, revoked} = Accounts.revoke_scope(scope, tenant: "CO", actor: ctx.admin)
      assert revoked.revoked_by == ctx.admin.id
      assert %DateTime{} = revoked.revoked_at
    end

    @tag spec: "ACCT-10"
    test "a revoked scope stops authorizing on the next request and keeps its row", ctx do
      assert scopes(ctx.analyst) == [{"MX", :analyst}]

      [scope] = Accounts.list_scopes!(tenant: "MX", actor: ctx.admin)
      {:ok, _revoked} = Accounts.revoke_scope(scope, tenant: "MX", actor: ctx.admin)

      assert scopes(ctx.analyst) == []
      assert Actor.country_role(as_actor(ctx.analyst), "MX") == nil
      assert [%{revoked_by: revoked_by}] = Accounts.list_scopes!(tenant: "MX", actor: ctx.admin)
      assert revoked_by == ctx.admin.id
    end

    test "granting again restores the same scope", ctx do
      [scope] = Accounts.list_scopes!(tenant: "MX", actor: ctx.admin)
      {:ok, _revoked} = Accounts.revoke_scope(scope, tenant: "MX", actor: ctx.admin)

      assert {:error, error} = Accounts.revoke_scope(scope, tenant: "MX", actor: ctx.admin)
      assert Exception.message(error) =~ "is already revoked"

      {:ok, _scope} =
        Accounts.grant_scope(ctx.analyst.id, :risk_manager, tenant: "MX", actor: ctx.admin)

      assert [%{role: :risk_manager, revoked_at: nil, revoked_by: nil}] =
               Accounts.list_scopes!(tenant: "MX", actor: ctx.admin)

      assert scopes(ctx.analyst) == [{"MX", :risk_manager}]
    end

    @tag spec: "SEC-02"
    test "admins and auditors never act through country scopes", ctx do
      for user <- [ctx.admin, ctx.auditor] do
        assert {:error, error} =
                 Accounts.grant_scope(user.id, :analyst, tenant: "MX", actor: ctx.admin)

        assert Exception.message(error) =~ "never acts through country scopes"
      end

      assert {:error, error} =
               Accounts.grant_scope(Ash.UUIDv7.generate(), :analyst,
                 tenant: "MX",
                 actor: ctx.admin
               )

      assert Exception.message(error) =~ "is not a staff user"

      stray = %StaffScope{country_code: "MX", role: :analyst}
      assert Actor.country_role(%{ctx.admin | active_scopes: [stray]}, "MX") == nil
      assert Actor.global_role(ctx.admin) == :admin
    end
  end

  describe "the actor's scopes" do
    test "cover every country, whatever the request's country", ctx do
      Factory.scope(ctx.analyst, "ES", :risk_manager, ctx.admin)

      actor = as_actor(ctx.analyst, tenant: "CO")

      assert Enum.sort(Enum.map(actor.active_scopes, &{&1.country_code, &1.role})) ==
               [{"ES", :risk_manager}, {"MX", :analyst}]

      assert Actor.country_role(actor, "MX") == :analyst
      assert Actor.country_role(actor, "CO") == nil
    end

    test "are not loaded for a locked staff user", ctx do
      Factory.update_staff_user(ctx.analyst, status: "locked")

      assert {:error, _not_found} =
               AshAuthentication.subject_to_user(
                 AshAuthentication.user_to_subject(ctx.analyst),
                 StaffUser
               )
    end

    test "are only read through their staff user", ctx do
      for actor <- [as_actor(ctx.analyst), ctx.admin] do
        assert {:ok, []} = Ash.read(StaffScope, action: :active_for_actor, actor: actor)
      end
    end
  end

  describe "reading scopes" do
    test "staff read the scopes of a country where they work, and nowhere else", ctx do
      {other, _secret} = Factory.staff_user()
      Factory.scope(other, "CO", :analyst, ctx.admin)
      analyst = as_actor(ctx.analyst)

      assert [%{user_id: user_id}] = Accounts.list_scopes!(tenant: "MX", actor: analyst)
      assert user_id == ctx.analyst.id
      assert Accounts.list_scopes!(tenant: "CO", actor: analyst) == []
      assert [%{user_id: other_id}] = Accounts.list_scopes!(tenant: "CO", actor: ctx.admin)
      assert other_id == other.id
    end

    @tag spec: "MULT-04"
    test "only global roles read every country at once", ctx do
      for actor <- [ctx.admin, ctx.auditor] do
        assert [%{country_code: "MX"}] = Accounts.list_all_scopes!(actor: actor)
      end

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.list_all_scopes(actor: as_actor(ctx.analyst))

      assert {:error, %Ash.Error.Invalid{}} = Accounts.list_scopes(actor: ctx.admin)
    end
  end
end
