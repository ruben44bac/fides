defmodule FidesWeb.FormatTest do
  use ExUnit.Case, async: true

  alias FidesWeb.Format

  test "amounts carry their currency, with thousands and cents" do
    assert Format.amount(2_500_000, "EUR") == "EUR 25,000.00"
    assert Format.amount(5, "MXN") == "MXN 0.05"
    assert Format.amount(12_345_678_901, "COP") == "COP 123,456,789.01"
  end

  test "labels read as words" do
    assert Format.label(:amount_above_review_threshold) == "amount above review threshold"
    assert Format.label("in_review") == "in review"
    assert Format.label(nil) == ""
    assert Format.state(:pending_countersign) == "pending countersign"
  end

  test "actors read as the evidence names them, without an id in full" do
    assert Format.actor("staff_user:0199abcd-0000-7000-8000-000000000000") == "staff · 0199abcd"
    assert Format.actor("system:orchestrator") == "orchestrator"
    assert Format.actor("agent:risk") == "risk agent"
    assert Format.actor(nil) == "unknown"
  end

  test "numbers, durations, digests and moments" do
    assert Format.number(1_234_567) == "1,234,567"
    assert Format.duration(12) == "12 ms"
    assert Format.duration(1_250) == "1.3 s"
    assert Format.digest(:crypto.hash(:sha256, "x")) =~ ~r/^[0-9a-f]{12}$/
    assert Format.instant(~U[2026-10-12 10:00:05.123456Z]) == "2026-10-12 10:00:05"
    assert Format.moment(~U[2026-10-12 10:00:05Z]) == "2026-10-12 10:00"
    assert Format.relative(~U[2026-10-12 09:58:00Z], ~U[2026-10-12 10:00:05Z]) == "2 min ago"
  end
end
