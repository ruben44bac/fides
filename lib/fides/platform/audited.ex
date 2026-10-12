defmodule Fides.Platform.Audited do
  @moduledoc """
  Spark extension: turns audit rules into database triggers that the migration
  generator emits with the table, so no table depends on someone remembering them.

      audit do
        immutable [:code]
        filtered [:hashed_password]
      end

    * Carbonite captures every change to the table (`capture? false` opts out).
      Writing without an audit context then fails in the database.
    * `immutable` columns cannot change after insert. `country_code` is always
      immutable.
    * `filtered` columns are recorded as `[FILTERED]` in the evidence.
  """

  @audit %Spark.Dsl.Section{
    name: :audit,
    describe: "How the resource's table is audited.",
    schema: [
      capture?: [
        type: :boolean,
        default: true,
        doc: "Whether Carbonite captures the table's changes."
      ],
      immutable: [
        type: {:list, :atom},
        default: [],
        doc: "Columns that cannot change after insert, besides `country_code`."
      ],
      filtered: [
        type: {:list, :atom},
        default: [],
        doc: "Columns whose values Carbonite records as `[FILTERED]`."
      ]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@audit],
    persisters: [Fides.Platform.Audited.Persisters.AddAuditTriggers]
end
