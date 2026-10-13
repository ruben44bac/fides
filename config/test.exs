import Config
config :fides, Oban, testing: :manual
config :bcrypt_elixir, log_rounds: 1
config :ash, policies: [show_policy_breakdowns?: true], disable_async?: true

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :fides, Fides.Platform.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  # PostgreSQL 18 from deploy/compose.yml
  port: String.to_integer(System.get_env("FIDES_DB_PORT", "5434")),
  database: "fides_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :fides, FidesWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "0AHFrF5hhpHUXZucNXHPAeB2tsRZTqBFnTxlh6ywqZLwQRz7OZ1g+Yfml//mqLhE",
  server: false

# In test we don't send emails
config :fides, Fides.Platform.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Test keys, derived from fixed phrases: they protect nothing and are never
# used in production, where they come from the environment
config :fides, Fides.Platform.Vault,
  keys: [{"V1", :crypto.hash(:sha256, "fides test encryption key")}]

config :fides, Fides.Platform.BlindIndex, key: :crypto.hash(:sha256, "fides test blind index key")

config :fides, Fides.Accounts.StaffUser,
  token_signing_secret: :crypto.hash(:sha256, "fides test staff token key")

config :fides, Fides.Accounts.Demo, totp_seed: :crypto.hash(:sha256, "fides test totp seed")

# Lets the token task call the endpoint in the test process
config :fides, Mix.Tasks.Fides.Token, req_options: [plug: {Req.Test, Mix.Tasks.Fides.Token}]

# Bank providers are stubbed in each test
config :fides, Fides.Banking.Client,
  base_url: "http://providers.test",
  req_options: [plug: {Req.Test, Fides.Banking.Client}]

config :fides, Fides.Banking.Callback, secret: "fides test provider webhook secret"

# Delayed moves are due at once
config :fides, Fides.Orchestration, retry_after: 0, callback_timeout: 0
