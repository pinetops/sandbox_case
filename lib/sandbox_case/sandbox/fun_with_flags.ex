defmodule SandboxCase.Sandbox.FunWithFlags do
  @moduledoc """
  Sandbox adapter for FunWithFlags. Works with vanilla FunWithFlags — no fork required.

  On setup, patches `FunWithFlags.Store` and `FunWithFlags.SimpleStore` to
  check the process dictionary for sandbox overrides, then starts a pool
  of isolated ETS tables.

      config :sandbox_case,
        sandbox: [fun_with_flags: true]
  """
  @behaviour SandboxCase.Sandbox.Adapter
  use GenServer

  @impl true
  def available? do
    Code.ensure_loaded?(FunWithFlags)
  end

  @impl true
  def setup(config) do
    pool_size =
      case config do
        c when is_list(c) -> Keyword.get(c, :pool_size, System.schedulers_online())
        _ -> System.schedulers_online()
      end

    # Patch Store/SimpleStore to check process dictionary
    SandboxCase.Sandbox.FwfPatcher.patch!()

    # Start the pool
    {:ok, _} = GenServer.start_link(__MODULE__, pool_size, name: __MODULE__)
    :ok
  end

  @impl true
  def propagate_keys(_config), do: [:fwf_sandbox]

  @impl true
  def checkout(config) do
    if Process.whereis(__MODULE__) do
      table = GenServer.call(__MODULE__, :checkout)
      Process.put(:fwf_sandbox, table)

      # Pre-seed flags if configured
      flags =
        case config do
          c when is_list(c) -> Keyword.get(c, :flags, [])
          _ -> []
        end

      gate_mod = Module.concat([FunWithFlags, Gate])

      for {flag_name, enabled} <- flags do
        gate = gate_mod.new(:boolean, enabled)
        SandboxCase.Sandbox.FwfStore.put(table, flag_name, gate)
      end

      table
    end
  end

  @impl true
  def checkin(nil), do: :ok

  def checkin(table) do
    Process.delete(:fwf_sandbox)

    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:checkin, table})
    end

    :ok
  end

  # --- GenServer pool ---

  @impl true
  def init(pool_size) do
    tables =
      for i <- 1..pool_size do
        :ets.new(:"fwf_sandbox_#{i}", [:set, :public, read_concurrency: true])
      end

    {:ok, %{available: tables, waiting: :queue.new()}}
  end

  @impl true
  def handle_call(:checkout, _from, %{available: [table | rest]} = state) do
    :ets.delete_all_objects(table)
    {:reply, table, %{state | available: rest}}
  end

  def handle_call(:checkout, from, %{available: []} = state) do
    {:noreply, %{state | waiting: :queue.in(from, state.waiting)}}
  end

  def handle_call({:checkin, table}, _from, %{available: available, waiting: waiting} = state) do
    case :queue.out(waiting) do
      {{:value, next}, new_waiting} ->
        :ets.delete_all_objects(table)
        GenServer.reply(next, table)
        {:reply, :ok, %{state | waiting: new_waiting}}

      {:empty, _} ->
        {:reply, :ok, %{state | available: [table | available]}}
    end
  end
end
