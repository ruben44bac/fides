defmodule Mix.Tasks.Fides.TokenTest do
  # Swaps the global Mix shell
  use FidesWeb.ConnCase, async: false

  alias Fides.Accounts.Demo
  alias Mix.Tasks.Fides.Token

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    # The task's requests reach the endpoint in this process
    Req.Test.stub(Token, &FidesWeb.Endpoint.call(&1, FidesWeb.Endpoint.init([])))

    demo = Demo.user("analyst_mx")

    {user, _secret} =
      Fides.Factory.staff_user(
        email: demo.email,
        password: Demo.password(),
        totp_secret: Demo.totp_secret("analyst_mx")
      )

    %{user: user}
  end

  test "prints a token for a demo staff user" do
    Token.run(["analyst_mx"])

    assert_received {:mix_shell, :info, [token]}

    assert {:ok, %{"sub" => "staff_user?id=" <> _id}, _resource} =
             AshAuthentication.Jwt.verify(token, :fides)
  end

  test "explains a refused sign-in and a wrong handle", %{user: user} do
    # Every code is spent, whatever the step when the task runs
    Fides.Factory.update_staff_user(user, totp_last_used_at: ~U[2100-01-01 00:00:00.000000Z])

    assert_raise Mix.Error, ~r/A code works once/, fn -> Token.run(["analyst_mx"]) end
    assert_raise Mix.Error, ~r/No demo staff user "nobody"/, fn -> Token.run(["nobody"]) end
    assert_raise Mix.Error, ~r/Usage/, fn -> Token.run([]) end
  end

  test "explains an app that is down or failing" do
    Req.Test.stub(Token, &Req.Test.transport_error(&1, :econnrefused))
    assert_raise Mix.Error, ~r/Is the app running\?/, fn -> Token.run(["analyst_mx"]) end

    Req.Test.stub(Token, &Plug.Conn.send_resp(&1, 500, ""))
    assert_raise Mix.Error, ~r/answered 500/, fn -> Token.run(["analyst_mx"]) end
  end
end
