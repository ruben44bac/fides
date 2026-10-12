defmodule Fides.Origination.LifecycleDiagramTest do
  use ExUnit.Case, async: true

  alias Fides.Origination.Lifecycle.Diagram

  test "the committed diagrams match each country's life cycle" do
    assert File.read(Diagram.path()) == {:ok, Diagram.render()},
           "#{Diagram.path()} is out of date. Run `mix fides.gen.lifecycles`."
  end

  test "each country has its diagram, with what runs on entering each state" do
    diagrams = Diagram.render()

    for country <- Fides.Origination.Lifecycle.countries() do
      assert diagrams =~ "## #{country}\n"
    end

    assert diagrams =~ "  awaiting_bank_data --> awaiting_bank_callback: system"

    assert diagrams =~
             "  in_review --> pending_countersign: analyst, above the countersign threshold"

    assert diagrams =~ "| `awaiting_bank_callback` | Timeout `bank_callback` |"
    assert diagrams =~ "| `cancelled` | Nothing |"
  end
end
