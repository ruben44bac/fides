defmodule Fides.Platform.PureCoreTest do
  use ExUnit.Case, async: true

  @tag spec: "PLAT-05"
  test "document validators, the risk engine and the life cycles depend on nothing" do
    for module <- [Fides.Identity.Documents, Fides.Risk.Engine, Fides.Origination.Lifecycle] do
      [boundary] = module.__info__(:attributes)[Boundary]

      assert boundary.opts[:type] == :strict, "#{inspect(module)} must be a strict boundary"
      assert boundary.opts[:deps] == [], "#{inspect(module)} must not depend on anything"
    end
  end
end
