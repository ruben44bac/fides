defmodule Fides.Platform.ContextTest do
  use ExUnit.Case, async: true

  alias Fides.Platform.Context

  test "maps a module to the root of its context by name" do
    assert Context.of(Fides.Risk.Engine.Rules) == Fides.Risk
    assert Context.of(Fides.Countries) == Fides.Countries
  end

  test "modules outside a context have none" do
    assert Context.of(Fides.Platform.Repo) == nil
    assert Context.of(FidesWeb.Router) == nil
    assert Context.of(:crypto) == nil
    assert Context.of(nil) == nil
    assert Context.of("Fides.Risk") == nil
  end
end
