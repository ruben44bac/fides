defmodule Fides.ApplicationTest do
  use ExUnit.Case, async: true

  alias Fides.Application

  @oban [
    queues: [orchestration: 10, risk: 5],
    plugins: [{Oban.Plugins.Pruner, []}],
    repo: Fides.Platform.Repo
  ]

  test "a web node enqueues jobs and runs none; a worker, or a node that does both, runs them all" do
    web = Application.oban_config("web", @oban)
    assert web[:queues] == false and web[:plugins] == false
    assert web[:repo] == Fides.Platform.Repo

    assert Application.oban_config("worker", @oban) == @oban
    assert Application.oban_config("all", @oban) == @oban
  end
end
