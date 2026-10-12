defmodule FidesWeb.Router do
  use FidesWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {FidesWeb.Layouts, :root}
    plug :protect_from_forgery

    plug :put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self' data:; connect-src 'self' ws: wss:; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'"
    }

    plug FidesWeb.ContentSecurityPolicy
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :staff_api do
    plug FidesWeb.AuthenticateStaff
    plug FidesWeb.Idempotency
  end

  # Public: signing in, and the document that describes the API
  scope "/api", FidesWeb do
    pipe_through :api

    post "/auth/token", StaffTokenController, :create
    get "/open_api", OpenApiController, :show
  end

  scope "/api" do
    pipe_through :api

    forward "/swaggerui", OpenApiSpex.Plug.SwaggerUI,
      path: "/api/open_api",
      default_model_expand_depth: 4
  end

  # Everything else takes a staff bearer token
  scope "/api", FidesWeb do
    pipe_through [:api, :staff_api]

    delete "/auth/token", StaffTokenController, :delete
  end

  scope "/api" do
    pipe_through [:api, :staff_api]

    forward "/", FidesWeb.AshJsonApiRouter
  end

  scope "/", FidesWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:fides, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard",
        metrics: FidesWeb.Telemetry,
        csp_nonce_assign_key: :csp_nonce

      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
