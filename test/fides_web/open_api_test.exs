defmodule FidesWeb.OpenApiTest do
  use FidesWeb.ConnCase, async: true

  test "serves the OpenAPI document of the API to anyone, with its bearer authentication",
       %{conn: conn} do
    document = conn |> get("/api/open_api") |> response(200) |> Jason.decode!()

    assert %{"openapi" => "3." <> _, "info" => %{"title" => "Fides API"}} = document
    assert %{"bearer" => %{"scheme" => "bearer"}} = document["components"]["securitySchemes"]
    assert document["security"] == [%{"bearer" => []}]
  end

  test "serves the API's explorer", %{conn: conn} do
    assert conn |> get("/api/swaggerui") |> html_response(200) =~ "/api/open_api"
  end
end
