defmodule FidesWeb.OpenApiController do
  @moduledoc """
  Serves the API's OpenAPI document, generated from the resources' routes. Public, so
  anyone can read how to call the API; calling it takes a staff bearer token.
  """

  use FidesWeb, :controller

  alias OpenApiSpex.Schema

  def show(conn, _params) do
    spec =
      AshJsonApi.OpenApi.spec(
        [
          domains: FidesWeb.AshJsonApiRouter.domains(),
          prefix: "/api",
          open_api_title: "Fides API",
          open_api_version: "1",
          phoenix_endpoint: FidesWeb.Endpoint,
          modify_open_api: {__MODULE__, :complete, []}
        ],
        conn
      )

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(spec))
  end

  @doc false
  def complete(spec, _conn, _opts), do: spec |> bearer_auth() |> list_links() |> resource_links()

  # Every operation takes the staff bearer token that `POST /api/auth/token` issues
  defp bearer_auth(spec) do
    scheme = %OpenApiSpex.SecurityScheme{type: "http", scheme: "bearer", bearerFormat: "JWT"}
    components = spec.components || %OpenApiSpex.Components{}
    schemes = Map.put(components.securitySchemes || %{}, "bearer", scheme)

    %{
      spec
      | components: %{components | securitySchemes: schemes},
        security: [%{"bearer" => []}]
    }
  end

  # Lists answer with paging links and the JSON:API version too, which the generated
  # schema leaves out while it refuses any other key
  defp list_links(spec), do: %{spec | paths: Map.new(spec.paths, &with_list_links/1)}

  defp with_list_links({path, %{get: %{responses: %{200 => response} = responses} = get} = item}) do
    content =
      Map.new(response.content, fn {type, media} ->
        {type, %{media | schema: links(media.schema)}}
      end)

    {path,
     %{item | get: %{get | responses: %{responses | 200 => %{response | content: content}}}}}
  end

  defp with_list_links(path_item), do: path_item

  defp links(%Schema{properties: %{data: %Schema{type: :array}} = properties} = schema),
    do: %{schema | properties: Map.merge(properties, %{links: open(), jsonapi: open()})}

  defp links(schema), do: schema

  # Each resource object answers with its links and meta as well
  defp resource_links(%{components: %{schemas: schemas} = components} = spec) do
    schemas =
      Map.new(schemas, fn
        {name, %Schema{properties: %{attributes: _, type: _} = properties} = schema} ->
          {name, %{schema | properties: Map.merge(properties, %{links: open(), meta: open()})}}

        other ->
          other
      end)

    %{spec | components: %{components | schemas: schemas}}
  end

  defp open, do: %Schema{type: :object, additionalProperties: true}
end
