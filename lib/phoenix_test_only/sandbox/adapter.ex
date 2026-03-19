defmodule PhoenixTestOnly.Sandbox.Adapter do
  @moduledoc """
  Behaviour for sandbox adapters.

  Each adapter handles setup (once in test_helper), checkout (per test),
  and checkin (on_exit). The adapter returns an opaque token from checkout
  that is passed back to checkin.
  """

  @doc "One-time setup in test_helper. Receives adapter-specific config."
  @callback setup(config :: term()) :: :ok

  @doc "Per-test checkout. Returns an opaque token or nil."
  @callback checkout(config :: term()) :: term() | nil

  @doc "Per-test checkin. Receives the token from checkout."
  @callback checkin(token :: term()) :: :ok

  @doc "Whether this adapter is available (deps loaded)."
  @callback available?() :: boolean()
end
