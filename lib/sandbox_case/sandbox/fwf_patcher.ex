defmodule SandboxCase.Sandbox.FwfPatcher do
  @moduledoc false
  # Patches FunWithFlags.Store (and SimpleStore) at runtime to check
  # the process dictionary (and $callers) for sandbox overrides.
  # When :fwf_sandbox is set, all operations are redirected to an
  # isolated ETS table.

  @store FunWithFlags.Store
  @simple_store FunWithFlags.SimpleStore

  @doc false
  def patch! do
    patch_module(@store)
    patch_module(@simple_store)
  end

  defp patch_module(mod) do
    cond do
      not Code.ensure_loaded?(mod) ->
        :not_loaded

      already_patched?(mod) ->
        :already_patched

      not function_exported?(mod, :lookup, 1) ->
        require Logger
        Logger.warning("SandboxCase: #{inspect(mod)} doesn't export lookup/1, skipping patch")
        :unexpected_shape

      true ->
        do_patch(mod)
    end
  end

  defp already_patched?(mod) do
    source = get_beam_source(mod)
    source != nil and String.contains?(source, "fwf_sandbox_table")
  end

  defp get_beam_source(mod) do
    case :code.get_object_code(mod) do
      {_, beam, _} ->
        case :beam_lib.chunks(beam, [:abstract_code]) do
          {:ok, {_, [{:abstract_code, {:raw_abstract_v1, forms}}]}} ->
            inspect(forms)

          _ ->
            nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp do_patch(mod) do
    # Capture the original module's functions before replacing
    Code.compiler_options(ignore_module_conflict: true)

    Module.create(
      mod,
      patched_store_ast(mod),
      Macro.Env.location(__ENV__)
    )

    Code.compiler_options(ignore_module_conflict: false)
    :ok
  rescue
    e ->
      require Logger
      Logger.warning("SandboxCase: failed to patch #{inspect(mod)}: #{Exception.message(e)}")
      :error
  end

  # The patched module wraps every public function:
  # if :fwf_sandbox is found (directly or via $callers), use our ETS store.
  # Otherwise, delegate to the original implementation via :code.
  defp patched_store_ast(mod) do
    quote do
      @moduledoc false
      @original_mod unquote(mod)

      def lookup(flag_name) do
        case fwf_sandbox_table() do
          nil -> original_lookup(flag_name)
          table -> SandboxCase.Sandbox.FwfStore.lookup(table, flag_name)
        end
      end

      def put(flag_name, gate) do
        case fwf_sandbox_table() do
          nil -> original_put(flag_name, gate)
          table -> SandboxCase.Sandbox.FwfStore.put(table, flag_name, gate)
        end
      end

      def delete(flag_name, gate) do
        case fwf_sandbox_table() do
          nil -> original_delete(flag_name, gate)
          table -> SandboxCase.Sandbox.FwfStore.delete(table, flag_name, gate)
        end
      end

      def delete(flag_name) do
        case fwf_sandbox_table() do
          nil -> original_delete_flag(flag_name)
          table -> SandboxCase.Sandbox.FwfStore.delete(table, flag_name)
        end
      end

      def all_flags do
        case fwf_sandbox_table() do
          nil -> original_all_flags()
          table -> SandboxCase.Sandbox.FwfStore.all_flags(table)
        end
      end

      def all_flag_names do
        case fwf_sandbox_table() do
          nil -> original_all_flag_names()
          table -> SandboxCase.Sandbox.FwfStore.all_flag_names(table)
        end
      end

      # Delegate other functions that Store has
      def reload(flag_name) do
        case fwf_sandbox_table() do
          nil ->
            if function_exported?(@original_mod, :reload, 1) do
              # Can't call original after replacement — just do a lookup
              lookup(flag_name)
            else
              {:error, :not_supported}
            end

          table ->
            SandboxCase.Sandbox.FwfStore.lookup(table, flag_name)
        end
      end

      defp fwf_sandbox_table do
        case Process.get(:fwf_sandbox) do
          nil -> find_fwf_sandbox_in_callers(Process.get(:"$callers") || [])
          table -> table
        end
      end

      defp find_fwf_sandbox_in_callers([]), do: nil

      defp find_fwf_sandbox_in_callers([pid | rest]) do
        case :erlang.process_info(pid, :dictionary) do
          {:dictionary, dict} ->
            case List.keyfind(dict, :fwf_sandbox, 0) do
              {:fwf_sandbox, table} -> table
              _ -> find_fwf_sandbox_in_callers(rest)
            end

          _ ->
            find_fwf_sandbox_in_callers(rest)
        end
      catch
        _, _ -> find_fwf_sandbox_in_callers(rest)
      end

      # Original implementations — called when not sandboxed.
      # These replicate the vanilla Store/SimpleStore logic since we
      # can't call the original module after replacing it.

      if @original_mod == FunWithFlags.Store do
        defp original_lookup(flag_name) do
          alias FunWithFlags.Store.Cache
          alias FunWithFlags.{Config, Telemetry}

          case Cache.get(flag_name) do
            {:ok, flag} ->
              {:ok, flag}

            {:miss, reason, stale_value_or_nil} ->
              case Config.persistence_adapter().get(flag_name) do
                {:ok, flag} ->
                  Telemetry.emit_persistence_event({:ok, nil}, :read, flag_name, nil)
                  Cache.put(flag)
                  {:ok, flag}

                err = {:error, _reason} ->
                  Telemetry.emit_persistence_event(err, :read, flag_name, nil)

                  case reason do
                    :expired ->
                      require Logger

                      Logger.warning(
                        "FunWithFlags: couldn't load flag '#{flag_name}' from storage, falling back to stale cached value from ETS"
                      )

                      {:ok, stale_value_or_nil}

                    _ ->
                      raise "Can't load feature flag '#{flag_name}' from neither storage nor the cache"
                  end
              end
          end
        end

        defp original_put(flag_name, gate) do
          alias FunWithFlags.{Config, Store.Cache, Flag, Telemetry}

          result =
            flag_name
            |> Config.persistence_adapter().put(gate)
            |> Telemetry.emit_persistence_event(:write, flag_name, gate)

          if Config.change_notifications_enabled?() do
            case result do
              {:ok, %Flag{name: n}} -> Config.notifications_adapter().publish_change(n)
              _ -> :ok
            end
          end

          case result do
            {:ok, flag} ->
              Cache.put(flag)
              result

            _ ->
              result
          end
        end

        defp original_delete(flag_name, gate) do
          alias FunWithFlags.{Config, Store.Cache, Flag, Telemetry}

          result =
            flag_name
            |> Config.persistence_adapter().delete(gate)
            |> Telemetry.emit_persistence_event(:delete_gate, flag_name, gate)

          if Config.change_notifications_enabled?() do
            case result do
              {:ok, %Flag{name: n}} -> Config.notifications_adapter().publish_change(n)
              _ -> :ok
            end
          end

          case result do
            {:ok, flag} ->
              Cache.put(flag)
              result

            _ ->
              result
          end
        end

        defp original_delete_flag(flag_name) do
          alias FunWithFlags.{Config, Store.Cache, Flag, Telemetry}

          result =
            flag_name
            |> Config.persistence_adapter().delete()
            |> Telemetry.emit_persistence_event(:delete_flag, flag_name, nil)

          if Config.change_notifications_enabled?() do
            case result do
              {:ok, %Flag{name: n}} -> Config.notifications_adapter().publish_change(n)
              _ -> :ok
            end
          end

          case result do
            {:ok, flag} ->
              Cache.put(flag)
              result

            _ ->
              result
          end
        end

        defp original_all_flags do
          alias FunWithFlags.{Config, Telemetry}

          Config.persistence_adapter().all_flags()
          |> Telemetry.emit_persistence_event(:read_all_flags, nil, nil)
        end

        defp original_all_flag_names do
          alias FunWithFlags.{Config, Telemetry}

          Config.persistence_adapter().all_flag_names()
          |> Telemetry.emit_persistence_event(:read_all_flag_names, nil, nil)
        end
      else
        # SimpleStore — just delegates to persistence adapter with telemetry
        defp original_lookup(flag_name) do
          alias FunWithFlags.{Config, Telemetry}

          Config.persistence_adapter().get(flag_name)
          |> Telemetry.emit_persistence_event(:read, flag_name, nil)
        end

        defp original_put(flag_name, gate) do
          alias FunWithFlags.{Config, Telemetry}

          Config.persistence_adapter().put(flag_name, gate)
          |> Telemetry.emit_persistence_event(:write, flag_name, gate)
        end

        defp original_delete(flag_name, gate) do
          alias FunWithFlags.{Config, Telemetry}

          Config.persistence_adapter().delete(flag_name, gate)
          |> Telemetry.emit_persistence_event(:delete_gate, flag_name, gate)
        end

        defp original_delete_flag(flag_name) do
          alias FunWithFlags.{Config, Telemetry}

          Config.persistence_adapter().delete(flag_name)
          |> Telemetry.emit_persistence_event(:delete_flag, flag_name, nil)
        end

        defp original_all_flags do
          alias FunWithFlags.{Config, Telemetry}

          Config.persistence_adapter().all_flags()
          |> Telemetry.emit_persistence_event(:read_all_flags, nil, nil)
        end

        defp original_all_flag_names do
          alias FunWithFlags.{Config, Telemetry}

          Config.persistence_adapter().all_flag_names()
          |> Telemetry.emit_persistence_event(:read_all_flag_names, nil, nil)
        end
      end
    end
  end
end
