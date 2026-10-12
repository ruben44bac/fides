defmodule FidesWeb.AshJsonApiRouter do
  @moduledoc "JSON:API routes generated from the domains, with their OpenAPI document."

  use AshJsonApi.Router,
    domains: [],
    open_api: "/open_api"
end
