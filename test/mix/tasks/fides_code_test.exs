defmodule Mix.Tasks.Fides.CodeTest do
  # Swaps the global Mix shell
  use ExUnit.Case, async: false

  alias Fides.Accounts.Demo
  alias Fides.Accounts.Totp
  alias Mix.Tasks.Fides.Code

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  test "prints the code a demo staff user's authenticator shows now" do
    Code.run(["analyst_es"])

    assert_received {:mix_shell, :info, [line]}
    assert [code, _left] = String.split(line, "  ")
    assert {:ok, _step} = Totp.verify(Demo.totp_secret("analyst_es"), code)
  end

  test "explains a wrong handle and the usage" do
    assert_raise Mix.Error, ~r/No demo staff user "nobody"/, fn -> Code.run(["nobody"]) end
    assert_raise Mix.Error, ~r/Usage/, fn -> Code.run([]) end
  end
end
