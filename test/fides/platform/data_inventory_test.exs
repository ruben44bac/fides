defmodule Fides.Platform.DataInventoryTest do
  use ExUnit.Case, async: true

  alias Fides.Platform.DataInventory

  @tag spec: "PLAT-03"
  test "the committed inventory matches the classification" do
    assert File.read(DataInventory.path()) == {:ok, DataInventory.render()},
           "#{DataInventory.path()} is out of date. Run `mix fides.gen.inventory`."
  end

  test "the inventory lists every attribute with its class" do
    inventory = DataInventory.render()

    assert inventory =~ "## Fides.Countries.Country (`countries`)"
    assert inventory =~ "| `code` | Ash.Type.String | public |"
  end
end
