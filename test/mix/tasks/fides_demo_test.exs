defmodule Mix.Tasks.Fides.DemoTest do
  # Swaps the global Mix shell
  use Fides.DataCase, async: false

  alias Mix.Tasks.Fides.Demo

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    :ok
  end

  test "says where it runs, and fails when the app cannot be reached" do
    Req.Test.stub(Fides.Demo, &Req.Test.transport_error(&1, :econnrefused))

    assert_raise Mix.Error, ~r/Is the app running\?/, fn -> Demo.run([]) end
    assert_received {:mix_shell, :info, [first_line]}
    assert first_line =~ "Fides demo against http://localhost:4000"
    assert first_line =~ "/backoffice"
  end
end
