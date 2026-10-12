defmodule Fides.Platform.BoundaryCompat do
  @moduledoc """
  Lets a module be both a `Boundary` root and a Spark DSL module (an Ash domain).

  Both libraries keep their options in `@opts` and read it in `@before_compile`, so
  whichever `use` comes last wins and the other silently loses its options. This shim
  wraps Boundary's `@before_compile` between two hooks that swap the right `@opts` in
  and out. It must come before the Spark `use`; `Fides.Platform.Domain` does that.
  """

  defmacro __using__(opts) do
    quote do
      if Module.has_attribute?(__MODULE__, :spark_parent) do
        raise CompileError,
          file: __ENV__.file,
          line: __ENV__.line,
          description: "use #{inspect(unquote(__MODULE__))} must come before the Spark DSL `use`"
      end

      @before_compile {unquote(__MODULE__), :__put_boundary_opts__}
      use Boundary, unquote(opts)
      Module.put_attribute(__MODULE__, :__fides_boundary_opts__, @opts)
      @before_compile {unquote(__MODULE__), :__put_spark_opts__}
    end
  end

  @doc false
  defmacro __put_boundary_opts__(env) do
    Module.put_attribute(
      env.module,
      :__fides_spark_opts__,
      Module.get_attribute(env.module, :opts)
    )

    Module.put_attribute(
      env.module,
      :opts,
      Module.get_attribute(env.module, :__fides_boundary_opts__)
    )

    nil
  end

  @doc false
  defmacro __put_spark_opts__(env) do
    Module.put_attribute(
      env.module,
      :opts,
      Module.get_attribute(env.module, :__fides_spark_opts__)
    )

    nil
  end
end
