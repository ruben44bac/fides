defmodule Fides.Platform.ContextIsolation do
  @moduledoc """
  Spark extension (no DSL): a resource belongs to the context its module name says,
  uses that context's domain, and none of its relationships leaves the context.
  Other contexts are reached through ids and code interfaces.
  """

  use Spark.Dsl.Extension,
    sections: [],
    persisters: [Fides.Platform.ContextIsolation.Persisters.NoCrossContextRelationships]
end
