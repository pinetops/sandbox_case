defmodule SandboxCase.Sandbox.Propagator do
  @moduledoc false
  # Shared logic for propagating test sandbox state (Ecto, Mimic, Mox,
  # Cachex, FunWithFlags) from a test owner process to a child process.

  @doc "Propagate all sandbox state from owner to the current process."
  def propagate(owner, child \\ self()) do
    set_callers(owner)
    allow_mimic(owner, child)
    allow_mox(owner, child)
    propagate_keys(owner)
  end

  # Ecto — set $callers so this process and its sub-processes can access
  # the test sandbox via the ownership chain. Avoids the deadlock that
  # occurs with allow/3.
  defp set_callers(owner) do
    callers = Process.get(:"$callers") || []
    unless owner in callers, do: Process.put(:"$callers", [owner | callers])
  end

  defp allow_mimic(owner, child) do
    mimic = Module.concat([Mimic])

    if Code.ensure_loaded?(mimic) do
      server = Module.concat([Mimic, Server])

      for mod <- mimic_modules(server) do
        mimic.allow(mod, owner, child)
      end
    end
  catch
    _, _ -> :ok
  end

  defp mimic_modules(server) do
    :sys.get_state(server).modules_opts |> Map.keys()
  catch
    _, _ -> []
  end

  defp allow_mox(owner, child) do
    mox = Module.concat([Mox])

    if Code.ensure_loaded?(mox) do
      mocks =
        Application.get_env(:sandbox_case, :mox_mocks, []) ++
          Application.get_env(:wallabidi, :mox_mocks, [])

      for mod <- Enum.uniq(mocks) do
        mox.allow(mod, owner, child)
      end
    end
  catch
    _, _ -> :ok
  end

  # O(k) where k = number of sandbox keys, not O(n) over entire process dictionary.
  defp propagate_keys(owner) do
    keys = SandboxCase.Sandbox.propagate_keys()

    case :erlang.process_info(owner, :dictionary) do
      {:dictionary, dict} ->
        for key <- keys do
          case List.keyfind(dict, key, 0) do
            {^key, value} -> Process.put(key, value)
            _ -> :ok
          end
        end

      _ ->
        :ok
    end
  catch
    _, _ -> :ok
  end
end
