defmodule FidesWeb.HealthControllerTest do
  use FidesWeb.ConnCase, async: true

  test "answers ok while the database answers", %{conn: conn} do
    conn = get(conn, ~p"/health")

    assert json_response(conn, 200) == %{"status" => "ok"}
  end
end
