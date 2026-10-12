defmodule Fides.Platform.AuditTracerTest do
  use ExUnit.Case, async: true

  alias Fides.Platform.AuditContext
  alias Fides.Platform.AuditTracer

  setup do
    on_exit(fn -> AuditContext.clear() end)
  end

  defp span(tenant, fun) do
    AuditTracer.start_span(:action, "probe")
    AuditTracer.set_metadata(:action, %{tenant: tenant})

    try do
      fun.()
    after
      AuditTracer.stop_span()
    end
  end

  test "knows the tenant of the innermost action that has one" do
    assert AuditTracer.tenant() == nil

    span("ES", fn ->
      assert AuditTracer.tenant() == "ES"
      span(nil, fn -> assert AuditTracer.tenant() == "ES" end)
      span("MX", fn -> assert AuditTracer.tenant() == "MX" end)
      assert AuditTracer.tenant() == "ES"
    end)

    assert AuditTracer.tenant() == nil
  end

  test "only follows action spans" do
    assert AuditTracer.trace_type?(:action)
    assert AuditTracer.trace_type?(:bulk_create)
    refute AuditTracer.trace_type?(:query)
  end

  test "carries the audit context and the tenant into processes Ash starts" do
    AuditContext.put(actor: "system:test", reason: "bulk work")

    span("PT", fn ->
      task =
        Ash.ProcessHelpers.async(fn -> {AuditContext.get(), AuditTracer.tenant()} end,
          tracer: [AuditTracer]
        )

      assert {%{actor: "system:test", reason: "bulk work"}, "PT"} = Task.await(task)
    end)
  end
end
