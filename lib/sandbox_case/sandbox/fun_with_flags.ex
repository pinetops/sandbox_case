defmodule SandboxCase.Sandbox.FunWithFlags do
  @moduledoc false
  @behaviour SandboxCase.Sandbox.Adapter

  @impl true
  def available? do
    Code.ensure_loaded?(FunWithFlags.Sandbox)
  end

  @impl true
  def setup(config) do
    opts = if is_list(config), do: config, else: []
    {:ok, _} = FunWithFlags.Sandbox.start(opts)
    :ok
  end

  @impl true
  def checkout(config) do
    mod = FunWithFlags.Sandbox

    if Process.whereis(mod) do
      opts = if is_list(config), do: config, else: []
      mod.checkout(opts)
    end
  end

  @impl true
  def propagate_keys(_config), do: [:fwf_sandbox]

  @impl true
  def checkin(nil), do: :ok

  def checkin(token) do
    mod = FunWithFlags.Sandbox

    if Process.whereis(mod) do
      mod.checkin(token)
    end

    :ok
  end
end
