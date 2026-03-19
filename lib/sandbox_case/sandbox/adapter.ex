defmodule SandboxCase.Sandbox.Adapter do
  @moduledoc """
  Behaviour for sandbox adapters.

  Each adapter handles setup (once in test_helper), checkout (per test),
  and checkin (on_exit). The adapter returns an opaque token from checkout
  that is passed back to checkin.

  Adapters can optionally declare plug and on_mount modules to be
  registered in endpoints and LiveViews via `sandbox_plugs()` and
  `sandbox_on_mount()`.
  """

  @doc "One-time setup in test_helper. Receives adapter-specific config."
  @callback setup(config :: term()) :: :ok

  @doc "Per-test checkout. Returns an opaque token or nil."
  @callback checkout(config :: term()) :: term() | nil

  @doc "Per-test checkin. Receives the token from checkout."
  @callback checkin(token :: term()) :: :ok

  @doc "Whether this adapter is available (deps loaded)."
  @callback available?() :: boolean()

  @doc "Plug modules to register in the endpoint. Return [] if none."
  @callback plugs() :: [module()]

  @doc "on_mount modules to register in LiveViews. Return [] if none."
  @callback hooks() :: [module()]

  @doc "Process dictionary keys to propagate to child processes. Return [] if none."
  @callback propagate_keys(config :: term()) :: [term()]

  @optional_callbacks [plugs: 0, hooks: 0, propagate_keys: 1]
end
