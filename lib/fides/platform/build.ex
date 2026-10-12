defmodule Fides.Platform.Build do
  @moduledoc """
  Build information recorded in every audited transaction.

  Release builds set `FIDES_CODE_SHA`; local builds fall back to `git rev-parse HEAD`
  at compile time, so in development the value can lag behind new commits.
  """

  @code_sha System.get_env("FIDES_CODE_SHA") ||
              (try do
                 case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
                   {sha, 0} -> String.trim(sha)
                   _ -> "unknown"
                 end
               rescue
                 ErlangError -> "unknown"
               end)

  @spec code_sha() :: String.t()
  def code_sha, do: @code_sha
end
