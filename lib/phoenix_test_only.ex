defmodule PhoenixTestOnly do
  @moduledoc """
  Compile-time conditional `plug` and `on_mount` for test-only modules.

  Phoenix's `plug` and `on_mount` macros accumulate module attributes at the
  top level. When wrapped in `if Application.compile_env(...)`, the call ends
  up inside a `case` node in the AST and Phoenix silently ignores it.

  These macros move the check to **macro expansion time**: the emitted code is
  either a bare `plug`/`on_mount` call or nothing at all. They only emit in
  test — if `Mix` isn't loaded (release) or `Mix.env()` isn't `:test`, nothing
  is emitted.

  ## Usage

      # endpoint.ex
      import PhoenixTestOnly
      plug_if_test Phoenix.Ecto.SQL.Sandbox
      plug_if_test Wallabidi.Sandbox.Plug

      # your_app_web.ex
      def live_view do
        quote do
          use Phoenix.LiveView
          import PhoenixTestOnly
          on_mount_if_test Wallabidi.Sandbox.Hook
        end
      end
  """

  @doc """
  Emits `plug(module)` if compiling in test env and the module is loaded;
  otherwise nothing.

  Any extra options are forwarded as plug options.

  ## Examples

      plug_if_test Phoenix.Ecto.SQL.Sandbox
      plug_if_test Wallabidi.Sandbox.Plug
      plug_if_test MyPlug, some_option: true
  """
  defmacro plug_if_test(module, opts \\ []) do
    module = Macro.expand(module, __CALLER__)

    if test_env?() and Code.ensure_loaded?(module) do
      if opts == [] do
        quote do: plug(unquote(module))
      else
        quote do: plug(unquote(module), unquote(opts))
      end
    end
  end

  @doc """
  Emits `on_mount(module)` if compiling in test env and the module is loaded;
  otherwise nothing.

  ## Examples

      on_mount_if_test Wallabidi.Sandbox.Hook
  """
  defmacro on_mount_if_test(module, _opts \\ []) do
    module = Macro.expand(module, __CALLER__)

    if test_env?() and Code.ensure_loaded?(module) do
      quote do: on_mount(unquote(module))
    end
  end

  @doc false
  def test_env? do
    function_exported?(Mix, :env, 0) and Mix.env() == :test
  end
end
