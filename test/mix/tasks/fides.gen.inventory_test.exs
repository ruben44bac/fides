defmodule Mix.Tasks.Fides.Gen.InventoryTest do
  # Writes the inventory file, so it must not run next to tests that read it.
  use ExUnit.Case, async: false

  alias Mix.Tasks.Fides.Gen.Inventory

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  test "writes the inventory, and the check passes once it is up to date" do
    Inventory.run([])
    assert_received {:mix_shell, :info, ["Wrote " <> path]}
    assert path == Fides.Platform.DataInventory.path()

    Inventory.run(["--check"])
  end

  test "rejects unknown options" do
    assert_raise OptionParser.ParseError, fn -> Inventory.run(["--force"]) end
  end
end
