defmodule Mix.Tasks.Fides.Gen.LifecyclesTest do
  # Writes the diagrams file, so it must not run next to tests that read it.
  use ExUnit.Case, async: false

  alias Mix.Tasks.Fides.Gen.Lifecycles

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  test "writes the diagrams, and the check passes once they are up to date" do
    Lifecycles.run([])
    assert_received {:mix_shell, :info, ["Wrote " <> path]}
    assert path == Fides.Origination.Lifecycle.Diagram.path()

    Lifecycles.run(["--check"])
  end

  test "rejects unknown options" do
    assert_raise OptionParser.ParseError, fn -> Lifecycles.run(["--force"]) end
  end
end
