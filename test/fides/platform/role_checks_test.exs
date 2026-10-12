defmodule Fides.Platform.RoleChecksTest do
  use ExUnit.Case, async: true

  alias Fides.Platform.Actor
  alias Fides.Platform.Checks.GlobalRole
  alias Fides.Platform.Checks.ScopedRole
  alias Fides.Platform.SystemActor

  test "a policy can only name existing roles" do
    assert {:ok, opts} = GlobalRole.init(roles: :admin)
    assert opts[:roles] == [:admin]
    assert {:error, _message} = GlobalRole.init(roles: [:analyst])
    assert {:error, _message} = GlobalRole.init([])

    assert {:ok, _opts} = ScopedRole.init(roles: [:analyst, :risk_manager])
    assert {:error, _message} = ScopedRole.init(roles: [:admin])
  end

  test "the checks describe themselves for policy breakdowns" do
    assert GlobalRole.describe(roles: [:admin]) =~ "global role"
    assert ScopedRole.describe(roles: [:analyst]) =~ "tenant's country"
  end

  test "anyone else, or no one, has no role" do
    for actor <- [nil, %{global_role: :admin}, SystemActor.new(:test)] do
      assert Actor.global_role(actor) == nil
      assert Actor.country_role(actor, "MX") == nil
      refute GlobalRole.match?(actor, %{}, roles: [:admin, :auditor])
    end
  end

  test "without a tenant, no scope applies" do
    refute ScopedRole.match?(nil, %{subject: %{to_tenant: nil}}, roles: [:analyst])
    refute ScopedRole.match?(nil, %{}, roles: [:analyst])
  end
end
