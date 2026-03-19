defmodule PhoenixTestOnly.Sandbox do
  @moduledoc """
  Orchestrates test sandbox setup and per-test checkout/checkin.

  ## Setup

  Call once in `test/test_helper.exs`:

      PhoenixTestOnly.Sandbox.setup()

  This reads config and runs each adapter's `setup/1`.

  ## Configuration

      # config/test.exs
      config :phoenix_test_only,
        otp_app: :my_app,
        sandbox: [
          ecto: true,                              # auto-discovers repos from otp_app
          cachex: [:my_cache],                     # cache names to sandbox
          fun_with_flags: true,                    # enable FWF sandbox pool
          mimic: [MyApp.External, MyApp.Payments], # modules to Mimic.copy
          mox: [{MyApp.MockWeather, MyApp.WeatherBehaviour}]
        ]

  Each key maps to a built-in adapter. You can also pass custom adapters:

      config :phoenix_test_only,
        sandbox: [
          {MyApp.CustomSandbox, [some: :config]}
        ]

  ## Per-test checkout

  Use the case template:

      use PhoenixTestOnly.Sandbox.Case

  Or call manually:

      tokens = PhoenixTestOnly.Sandbox.checkout()
      on_exit(fn -> PhoenixTestOnly.Sandbox.checkin(tokens) end)
  """

  @builtin_adapters %{
    ecto: PhoenixTestOnly.Sandbox.Ecto,
    cachex: PhoenixTestOnly.Sandbox.Cachex,
    fun_with_flags: PhoenixTestOnly.Sandbox.FunWithFlags,
    mimic: PhoenixTestOnly.Sandbox.Mimic,
    mox: PhoenixTestOnly.Sandbox.Mox
  }

  @doc """
  One-time setup. Call from test_helper.exs.
  """
  def setup(opts \\ []) do
    for {adapter, config} <- resolved_adapters(opts) do
      adapter.setup(config)
    end

    :ok
  end

  @doc """
  Per-test checkout. Returns a list of `{adapter, token}` tuples.
  Pass to `checkin/1` in `on_exit`.
  """
  def checkout(opts \\ []) do
    for {adapter, config} <- resolved_adapters(opts) do
      {adapter, adapter.checkout(config)}
    end
  end

  @doc """
  Per-test checkin. Accepts the list returned by `checkout/1`.
  """
  def checkin(tokens) when is_list(tokens) do
    for {adapter, token} <- tokens do
      adapter.checkin(token)
    end

    :ok
  end

  @doc """
  Returns the Ecto metadata from the most recent checkout, if any.
  Useful for passing to browser session start.
  """
  def ecto_metadata(tokens) when is_list(tokens) do
    case List.keyfind(tokens, PhoenixTestOnly.Sandbox.Ecto, 0) do
      {_, %{metadata: metadata}} -> metadata
      _ -> nil
    end
  end

  defp resolved_adapters(opts) do
    sandbox_config = opts[:sandbox] || Application.get_env(:phoenix_test_only, :sandbox, [])
    otp_app = opts[:otp_app] || Application.get_env(:phoenix_test_only, :otp_app)

    sandbox_config
    |> Enum.map(fn entry -> resolve_adapter(entry, otp_app) end)
    |> Enum.reject(&is_nil/1)
  end

  defp resolve_adapter({key, config}, otp_app) when is_atom(key) do
    case Map.get(@builtin_adapters, key) do
      nil ->
        # key is a custom adapter module
        if Code.ensure_loaded?(key) do
          {key, normalize_config(config, otp_app)}
        end

      adapter ->
        if adapter.available?() do
          {adapter, normalize_config(config, otp_app)}
        end
    end
  end

  defp resolve_adapter({adapter, config}, otp_app) when is_atom(adapter) do
    if Code.ensure_loaded?(adapter) do
      {adapter, normalize_config(config, otp_app)}
    end
  end

  defp normalize_config(true, otp_app), do: [otp_app: otp_app]
  defp normalize_config(config, otp_app) when is_list(config), do: Keyword.put_new(config, :otp_app, otp_app)
  defp normalize_config(config, _otp_app), do: config
end
