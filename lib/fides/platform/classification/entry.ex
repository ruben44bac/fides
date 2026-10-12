defmodule Fides.Platform.Classification.Entry do
  @moduledoc "One `attribute :name, :class` declaration inside `classification do ... end`."

  @classes [:pii, :financial, :pseudonymous, :internal, :public]

  @type class :: :pii | :financial | :pseudonymous | :internal | :public
  @type t :: %__MODULE__{
          name: atom(),
          class: class(),
          __identifier__: term(),
          __spark_metadata__: term()
        }

  # Spark needs __identifier__ because the entity declares `identifier: :name`, and
  # __spark_metadata__ to avoid a deprecation warning.
  defstruct [:name, :class, :__identifier__, __spark_metadata__: nil]

  @spec classes() :: [class()]
  def classes, do: @classes
end
