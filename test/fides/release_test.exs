defmodule Fides.ReleaseTest do
  # Seeds the same rows as the seed tests: running alone avoids waiting on their locks
  use Fides.DataCase, async: false

  alias Fides.Accounts.Demo
  alias Fides.Platform.Repo
  alias Fides.Release

  test "seeding twice leaves the countries and the demo staff once" do
    assert :ok = Release.seed()
    assert :ok = Release.seed()

    assert Repo.aggregate("countries", :count) == 6
    assert Repo.aggregate("staff_users", :count) == length(Demo.handles())
  end
end
