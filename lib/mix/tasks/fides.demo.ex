defmodule Mix.Tasks.Fides.Demo do
  @shortdoc "Runs the three scripted scenarios against the running app"

  @moduledoc """
  Runs the demo's three scenarios through the API of a running Fides, with the mocks
  running too, and follows each application state by state: one approved on its own,
  one approved after an analyst's review, and one the policy rejects through Mexico's
  asynchronous provider. Open the back office meanwhile to watch them move.

      mix fides.demo
      FIDES_URL=http://localhost:4000 mix fides.demo

  It fails when a scenario does not end as expected, or when the app or the mocks
  cannot be reached.
  """

  use Mix.Task
  use Boundary, classify_to: Fides.Mix

  @requirements ["app.config"]

  @impl true
  def run(_args) do
    {:ok, _apps} = Application.ensure_all_started(:req)
    url = System.get_env("FIDES_URL", "http://localhost:4000")

    case Fides.Demo.run(url: url, log: fn line -> Mix.shell().info(line) end) do
      :ok -> :ok
      {:error, reason} -> Mix.raise(reason)
    end
  end
end
