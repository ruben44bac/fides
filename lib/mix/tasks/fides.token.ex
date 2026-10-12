defmodule Mix.Tasks.Fides.Token do
  @shortdoc "Signs a demo staff user in and prints their bearer token"

  @moduledoc """
  Signs a demo staff user in through `POST /api/auth/token`, with their password and
  current TOTP code, and prints the token. The app must be running.

      mix fides.token analyst_mx
      FIDES_URL=http://localhost:4000 mix fides.token admin

  A code works once: signing the same user in twice within its 30 seconds fails the
  second time, until the next code.
  """

  use Mix.Task
  use Boundary, classify_to: Fides.Mix

  alias Fides.Accounts.Demo

  @requirements ["app.config"]

  @impl true
  def run(args) do
    demo = demo_user!(args)
    url = System.get_env("FIDES_URL", "http://localhost:4000") <> "/api/auth/token"
    {:ok, _apps} = Application.ensure_all_started(:req)

    body = %{
      email: demo.email,
      password: Demo.password(),
      totp_code: Demo.totp_code(demo.handle)
    }

    case Req.post(url, [json: body, retry: false] ++ req_options()) do
      {:ok, %{status: 200, body: %{"access_token" => token}}} ->
        Mix.shell().info(token)

      {:ok, %{status: 401}} ->
        Mix.raise(
          "Sign-in refused. A code works once: if #{demo.handle} already signed in with " <>
            "the current code, run this again when it changes."
        )

      {:ok, %{status: status}} ->
        Mix.raise("#{url} answered #{status}")

      {:error, exception} ->
        Mix.raise("Could not reach #{url}: #{Exception.message(exception)}. Is the app running?")
    end
  end

  defp demo_user!([handle]) do
    Demo.user(handle) ||
      Mix.raise("No demo staff user #{inspect(handle)}. Try one of: #{handles()}")
  end

  defp demo_user!(_args), do: Mix.raise("Usage: mix fides.token HANDLE, one of: #{handles()}")

  defp handles, do: Enum.join(Demo.handles(), ", ")

  defp req_options,
    do: :fides |> Application.get_env(__MODULE__, []) |> Keyword.get(:req_options, [])
end
