[
  import_deps: [
    :ash_cloak,
    :ash_ai,
    :ash_oban,
    :oban,
    :ash_json_api,
    :ash_state_machine,
    :ash_authentication_phoenix,
    :ash_authentication,
    :ash_phoenix,
    :ash_postgres,
    :ash,
    :reactor,
    :ecto,
    :ecto_sql,
    :phoenix,
    :stream_data
  ],
  # DSL options of the Fides.Platform extensions
  locals_without_parens: [capture?: 1, immutable: 1, filtered: 1],
  subdirectories: ["priv/*/migrations"],
  plugins: [Spark.Formatter, Phoenix.LiveView.HTMLFormatter],
  inputs: ["*.{heex,ex,exs}", "{config,lib,test}/**/*.{heex,ex,exs}", "priv/*/seeds.exs"]
]
