defmodule Fides.Platform.DomainTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  test "a context domain keeps both its boundary and its Ash options" do
    stderr =
      capture_io(:stderr, fn ->
        defmodule Elixir.Fides.Risk.RuntimeDomain do
          use Fides.Platform.Domain,
            boundary: [deps: [Fides.Platform], exports: []],
            validate_config_inclusion?: false

          resources do
            allow_unregistered? true
          end
        end
      end)

    [boundary] = Fides.Risk.RuntimeDomain.__info__(:attributes)[Boundary]
    assert boundary.opts[:deps] == [Fides.Platform]
    assert Ash.Domain.Info.allow_unregistered?(Fides.Risk.RuntimeDomain)
    refute stderr =~ "is not present in config"
  end

  test "the boundary options must be declared before the Ash domain" do
    assert_raise CompileError, ~r/must come before the Spark DSL/, fn ->
      defmodule Elixir.Fides.Risk.WrongOrderDomain do
        use Ash.Domain, otp_app: :fides, validate_config_inclusion?: false
        use Fides.Platform.BoundaryCompat, deps: []
      end
    end
  end
end
