defmodule SandboxCase do
  @moduledoc """
  Batteries-included test isolation for Elixir and Phoenix.

  ## Endpoint setup

      import SandboxCase
      sandbox_plugs()

      socket_with_sandbox "/live", Phoenix.LiveView.Socket,
        websocket: [connect_info: [session: @session_options]]

  ## LiveView setup

      import SandboxCase
      sandbox_on_mount()

  Outside test env, all macros emit their non-sandbox equivalents
  or nothing — zero overhead in production.
  """

  @doc """
  Emits `plug(mod)` for every plug declared by configured sandbox adapters.
  Emits nothing outside test env.
  """
  defmacro sandbox_plugs do
    if test_env?() do
      for mod <- SandboxCase.Sandbox.collect_plugs() do
        quote do: plug(unquote(mod))
      end
    end
  end

  @doc """
  Emits `on_mount(mod)` for every hook declared by configured sandbox adapters.
  Emits nothing outside test env.
  """
  defmacro sandbox_on_mount do
    if test_env?() do
      for mod <- SandboxCase.Sandbox.collect_hooks() do
        quote do: on_mount(unquote(mod))
      end
    end
  end

  @doc """
  Declares a Phoenix LiveView socket, injecting `:user_agent` into
  `connect_info` in test env so the sandbox Hook can read the owner PID.

  In production, emits a plain `socket/3` call without `:user_agent`.

  ## Example

      socket_with_sandbox "/live", Phoenix.LiveView.Socket,
        websocket: [connect_info: [session: @session_options]]

  In test, this becomes:

      socket "/live", Phoenix.LiveView.Socket,
        websocket: [connect_info: [:user_agent, session: @session_options]]
  """
  defmacro socket_with_sandbox(path, module, opts) do
    if test_env?() do
      opts = inject_user_agent(opts)
      quote do: socket(unquote(path), unquote(module), unquote(opts))
    else
      quote do: socket(unquote(path), unquote(module), unquote(opts))
    end
  end

  defp inject_user_agent(opts) do
    Keyword.update(opts, :websocket, [connect_info: [:user_agent]], fn ws_opts ->
      Keyword.update(ws_opts, :connect_info, [:user_agent], fn ci ->
        if :user_agent in ci, do: ci, else: [:user_agent | ci]
      end)
    end)
  end

  @doc false
  def test_env? do
    function_exported?(Mix, :env, 0) and Mix.env() == :test
  end
end
