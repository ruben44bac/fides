defmodule Fides.Platform.Classification do
  @moduledoc """
  Spark extension: every attribute of a resource must be classified.

      classification do
        attribute :email, :pii
        attribute :amount_minor, :financial
      end

  Classes: `:pii`, `:financial`, `:pseudonymous`, `:internal` and `:public`. An
  unclassified attribute is a compile error. `:pii` and `:internal` attributes are
  marked `sensitive?`, so Ash redacts them in inspect output and errors. For an
  AshCloak attribute, classify its logical name (`email`, not `encrypted_email`).
  """

  @attribute %Spark.Dsl.Entity{
    name: :attribute,
    describe: "Classifies one attribute of the resource.",
    examples: ["attribute :email, :pii"],
    target: Fides.Platform.Classification.Entry,
    args: [:name, :class],
    identifier: :name,
    schema: [
      name: [type: :atom, required: true, doc: "The attribute name."],
      class: [
        type: {:one_of, Fides.Platform.Classification.Entry.classes()},
        required: true,
        doc: "The data class."
      ]
    ]
  }

  @classification %Spark.Dsl.Section{
    name: :classification,
    describe: "Data classification of every attribute of the resource.",
    examples: [
      """
      classification do
        attribute :id, :pseudonymous
        attribute :email, :pii
      end
      """
    ],
    entities: [@attribute]
  }

  use Spark.Dsl.Extension,
    sections: [@classification],
    persisters: [Fides.Platform.Classification.Persisters.EnforceClassification]
end
