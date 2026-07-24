import Config

config :supabase, :pooler,
  enabled: false,
  tenant: "samay",
  pool_size: 5,
  default_port: 54329
