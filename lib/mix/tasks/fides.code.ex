defmodule Mix.Tasks.Fides.Code do
  @shortdoc "Prints the current second-factor code of a demo staff user"

  @moduledoc """
  Prints the code a demo staff user would read on their authenticator right now, to
  sign in to the backoffice, and how many seconds it stays current.

      mix fides.code analyst_es

  A code works once: signing in twice within its 30 seconds fails the second time.
  """

  use Mix.Task
  use Boundary, classify_to: Fides.Mix

  alias Fides.Accounts.Demo

  @requirements ["app.config"]

  @impl true
  def run([handle]) do
    if Demo.user(handle) do
      Mix.shell().info("#{Demo.totp_code(handle)}  (#{Demo.seconds_left()} s left)")
    else
      Mix.raise(
        "No demo staff user #{inspect(handle)}. Try one of: #{Enum.join(Demo.handles(), ", ")}"
      )
    end
  end

  def run(_args),
    do: Mix.raise("Usage: mix fides.code HANDLE, one of: #{Enum.join(Demo.handles(), ", ")}")
end
