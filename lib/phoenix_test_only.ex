defmodule PhoenixTestOnly do
  @moduledoc """
  Compile-time conditional `plug` and `on_mount` for test-only modules.

  Phoenix's `plug` and `on_mount` macros accumulate module attributes at the
  top level. When wrapped in `if Application.compile_env(...)`, the call ends
  up inside a `case` node in the AST and Phoenix silently ignores it.

  These macros move the check to **macro expansion time**: the emitted code is
  either a bare `plug`/`on_mount` call or nothing at all.

  ## Usage

      # endpoint.ex
      import PhoenixTestOnly
      plug_if_loaded(MyApp.Sandbox.Plug)

      # your_app_web.ex
      def live_view do
        quote do
          use Phoenix.LiveView
          import PhoenixTestOnly
          on_mount_if_loaded(MyApp.Sandbox.Hook)
        end
      end

  When the target module isn't loaded (e.g. a test-only dep not present in
  prod), the macro emits nothing — zero overhead, no dead code.
  """

  @doc """
  Emits `plug(module)` if the module is loaded at compile time; otherwise nothing.

  Any options not used for gating are forwarded as plug options.

  ## Options

  * `:otp_app` + `:key` — also check `Application.get_env(otp_app, key)` is truthy

  ## Examples

      plug_if_loaded(Wallabidi.Sandbox.Plug)
      plug_if_loaded(Phoenix.Ecto.SQL.Sandbox)
      plug_if_loaded(Wallabidi.Sandbox.Plug, otp_app: :wallabidi, key: :sandbox)
  """
  defmacro plug_if_loaded(module, opts \\ []) do
    module = Macro.expand(module, __CALLER__)
    {gate_opts, plug_opts} = Keyword.split(opts, [:otp_app, :key])

    if should_emit?(module, gate_opts) do
      if plug_opts == [] do
        quote do: plug(unquote(module))
      else
        quote do: plug(unquote(module), unquote(plug_opts))
      end
    end
  end

  @doc """
  Emits `on_mount(module)` if the module is loaded at compile time; otherwise nothing.

  ## Options

  * `:otp_app` + `:key` — also check `Application.get_env(otp_app, key)` is truthy

  ## Examples

      on_mount_if_loaded(Wallabidi.Sandbox.Hook)
      on_mount_if_loaded(Wallabidi.Sandbox.Hook, otp_app: :wallabidi, key: :sandbox)
  """
  defmacro on_mount_if_loaded(module, opts \\ []) do
    module = Macro.expand(module, __CALLER__)
    {gate_opts, _extra} = Keyword.split(opts, [:otp_app, :key])

    if should_emit?(module, gate_opts) do
      quote do: on_mount(unquote(module))
    end
  end

  @doc false
  def should_emit?(module, opts) do
    Code.ensure_loaded?(module) and config_gate_passes?(opts)
  end

  defp config_gate_passes?([]), do: true

  defp config_gate_passes?(opts) do
    app = Keyword.fetch!(opts, :otp_app)
    key = Keyword.fetch!(opts, :key)
    !!Application.get_env(app, key)
  end
end
