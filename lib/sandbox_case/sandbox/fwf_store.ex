defmodule SandboxCase.Sandbox.FwfStore do
  @moduledoc false
  # ETS-backed flag store for FunWithFlags sandbox isolation.
  # Uses runtime calls to FunWithFlags.Flag/Gate to avoid compile-time deps.

  def lookup(table, flag_name) do
    flag_mod = Module.concat([FunWithFlags, Flag])

    case :ets.lookup(table, flag_name) do
      [{^flag_name, gates}] -> {:ok, flag_mod.new(flag_name, gates)}
      [] -> {:ok, flag_mod.new(flag_name)}
    end
  end

  def put(table, flag_name, gate) do
    flag_mod = Module.concat([FunWithFlags, Flag])

    existing_gates =
      case :ets.lookup(table, flag_name) do
        [{^flag_name, gates}] -> gates
        [] -> []
      end

    new_gates = merge_gate(existing_gates, gate)
    :ets.insert(table, {flag_name, new_gates})
    {:ok, flag_mod.new(flag_name, new_gates)}
  end

  def delete(table, flag_name) do
    flag_mod = Module.concat([FunWithFlags, Flag])
    :ets.delete(table, flag_name)
    {:ok, flag_mod.new(flag_name)}
  end

  def delete(table, flag_name, gate) do
    flag_mod = Module.concat([FunWithFlags, Flag])

    case :ets.lookup(table, flag_name) do
      [{^flag_name, gates}] ->
        new_gates = remove_gate(gates, gate)
        :ets.insert(table, {flag_name, new_gates})
        {:ok, flag_mod.new(flag_name, new_gates)}

      [] ->
        {:ok, flag_mod.new(flag_name)}
    end
  end

  def all_flags(table) do
    flag_mod = Module.concat([FunWithFlags, Flag])

    flags =
      :ets.tab2list(table)
      |> Enum.map(fn {name, gates} -> flag_mod.new(name, gates) end)

    {:ok, flags}
  end

  def all_flag_names(table) do
    names =
      :ets.tab2list(table)
      |> Enum.map(fn {name, _gates} -> name end)

    {:ok, names}
  end

  defp merge_gate(gates, new_gate) do
    if Enum.any?(gates, &same_gate_id?(&1, new_gate)) do
      Enum.map(gates, fn existing ->
        if same_gate_id?(existing, new_gate), do: new_gate, else: existing
      end)
    else
      [new_gate | gates]
    end
  end

  defp remove_gate(gates, target) do
    Enum.reject(gates, &same_gate_id?(&1, target))
  end

  defp same_gate_id?(%{type: type, for: for1}, %{type: type, for: for2}) do
    case type do
      :percentage_of_time -> true
      :percentage_of_actors -> true
      _ -> for1 == for2
    end
  end

  defp same_gate_id?(_, _), do: false
end
