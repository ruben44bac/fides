defmodule Fides.Platform.PostgresExtension do
  @moduledoc """
  Database objects every audited table relies on, installed by the generated
  extensions migration before any resource table:

    * Carbonite (all its migration patches), which captures every change with the
      transaction's meta.
    * `fides_forbid_column_change(columns...)`, the trigger function behind the
      `immutable` option of `Fides.Platform.Audited`.
  """

  use AshPostgres.CustomExtension, name: "fides_platform", latest_version: 1

  @impl true
  def install(0) do
    ~S'''
    Carbonite.Migrations.up(1..12)

    execute("""
    CREATE FUNCTION fides_forbid_column_change() RETURNS trigger LANGUAGE plpgsql AS $$
    DECLARE
      col text;
    BEGIN
      FOREACH col IN ARRAY TG_ARGV LOOP
        IF (to_jsonb(OLD) -> col) IS DISTINCT FROM (to_jsonb(NEW) -> col) THEN
          RAISE EXCEPTION 'column % of %.% is immutable', col, TG_TABLE_SCHEMA, TG_TABLE_NAME
            USING ERRCODE = 'check_violation', CONSTRAINT = TG_TABLE_NAME || '_' || col || '_immutable';
        END IF;
      END LOOP;
      RETURN NEW;
    END
    $$
    """)
    '''
  end

  @impl true
  def uninstall(_version) do
    ~S'''
    execute("DROP FUNCTION IF EXISTS fides_forbid_column_change()")
    Carbonite.Migrations.down(12..1//-1)
    '''
  end
end
