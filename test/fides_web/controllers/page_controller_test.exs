defmodule FidesWeb.PageControllerTest do
  use FidesWeb.ConnCase, async: true

  test "the home leads to the backoffice", %{conn: conn} do
    assert redirected_to(get(conn, ~p"/")) == ~p"/backoffice"
  end
end
