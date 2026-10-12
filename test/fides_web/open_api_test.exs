defmodule FidesWeb.OpenApiTest do
  use FidesWeb.ConnCase, async: true

  test "serves the OpenAPI document of the JSON API", %{conn: conn} do
    conn = get(conn, "/api/json/open_api")

    assert %{"openapi" => "3." <> _, "info" => %{}} = Jason.decode!(response(conn, 200))
  end
end
