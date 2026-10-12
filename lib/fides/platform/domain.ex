defmodule Fides.Platform.Domain do
  @moduledoc """
  Base module for a context: the Ash domain is also the context's `Boundary` root,
  so other contexts may only call its code interfaces.

      use Fides.Platform.Domain,
        boundary: [deps: [Fides.Platform], exports: []]
  """

  defmacro __using__(opts) do
    {boundary, domain_opts} = Keyword.pop(opts, :boundary, [])
    domain_opts = Keyword.put_new(domain_opts, :otp_app, :fides)

    quote do
      use Fides.Platform.BoundaryCompat, unquote(boundary)
      use Ash.Domain, unquote(domain_opts)
    end
  end
end
