defmodule SandboxCase.Sandbox.Mimic do
  @moduledoc false
  @behaviour SandboxCase.Sandbox.Adapter

  @cache_key {__MODULE__, :copied_modules}

  @impl true
  def available? do
    Code.ensure_loaded?(Mimic)
  end

  @impl true
  def setup(config) do
    mimic = Module.concat([Mimic])
    modules = config[:modules] || config

    for mod <- modules do
      mimic.copy(mod)
    end

    :persistent_term.put(@cache_key, modules)

    :ok
  end

  @impl true
  def checkout(_config), do: nil

  @impl true
  def checkin(_token), do: :ok

  @doc """
  Returns the list of modules registered at setup time. Used by the
  Propagator to avoid an expensive `:sys.get_state(Mimic.Server)` call
  on every HTTP request — under concurrent load Mimic.Server's mailbox
  can be contended enough that serializing its full state times out or
  stalls, causing silent Mimic-stub propagation failures.
  """
  def copied_modules do
    :persistent_term.get(@cache_key, [])
  end
end
