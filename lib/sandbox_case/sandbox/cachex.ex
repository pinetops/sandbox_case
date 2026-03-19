defmodule SandboxCase.Sandbox.Cachex do
  @moduledoc false
  @behaviour SandboxCase.Sandbox.Adapter

  @impl true
  def available? do
    Code.ensure_loaded?(Cachex.Sandbox)
  end

  @impl true
  def setup(config) do
    names = extract_names(config)
    {:ok, _} = Cachex.Sandbox.start(names)
    :ok
  end

  @impl true
  def propagate_keys(config) do
    names = extract_names(config)
    Enum.map(names, &{:cachex_sandbox, &1})
  end

  defp extract_names(config) when is_list(config) do
    case Keyword.get(config, :names) do
      nil -> Enum.filter(config, &is_atom/1)
      names -> names
    end
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
