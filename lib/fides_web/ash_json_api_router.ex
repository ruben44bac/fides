defmodule FidesWeb.AshJsonApiRouter do
  @moduledoc """
  The JSON:API routes generated from the domains' resources, mounted at `/api`
  behind staff authentication. The OpenAPI document is served publicly by
  `FidesWeb.OpenApiController`.
  """

  use AshJsonApi.Router,
    domains: [Fides.Origination],
    prefix: "/api"
end
