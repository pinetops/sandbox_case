defmodule PhoenixTestOnly.Sandbox.Cachex do
  @moduledoc false
  @behaviour PhoenixTestOnly.Sandbox.Adapter

  @impl true
  def available? do
    Code.ensure_loaded?(Cachex.Sandbox)
  end

  @impl true
  def setup(config) do
    names = config[:names] || config
    {:ok, _} = Cachex.Sandbox.start(names)
    :ok
  end

  @impl true
  def checkout(_config) do
    mod = Cachex.Sandbox

    if Process.whereis(mod) do
      mod.checkout()
    end
  end

  @impl true
  def checkin(nil), do: :ok

  def checkin(token) do
    mod = Cachex.Sandbox

    if Process.whereis(mod) do
      mod.checkin(token)
    end

    :ok
  end
end
