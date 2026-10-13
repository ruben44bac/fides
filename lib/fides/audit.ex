defmodule Fides.Audit do
  @moduledoc """
  Audit context: what the evidence says. Carbonite keeps every write to the audited
  tables with who made it and why, and this context reads it back as the story of an
  application.
  """

  use Boundary, deps: [Fides.Platform], exports: []

  @doc """
  What happened to an application, in order: every audited transaction that wrote the
  application or its evidence, with who wrote, why, and what changed. Only public and
  financial columns are shown. Whoever asks must be allowed to see the application:
  the timeline itself checks nothing.
  """
  defdelegate timeline(application_id), to: Fides.Audit.Timeline, as: :build
end
