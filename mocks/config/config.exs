import Config

# Everything else comes from the environment at run time: see Mocks.Settings
config :mocks, start_server?: config_env() != :test

if config_env() == :test do
  config :mocks, req_options: [plug: {Req.Test, Mocks.Webhook}]
end
