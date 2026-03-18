defmodule PhoenixTestOnlyTest do
  use ExUnit.Case, async: true

  describe "should_emit?/2" do
    test "returns true for a loaded module with no opts" do
      assert PhoenixTestOnly.should_emit?(Kernel, [])
    end

    test "returns false for an unloaded module" do
      assert PhoenixTestOnly.should_emit?(NoSuchModule.AtAll, []) == false
    end

    test "checks config gate when otp_app and key given" do
      Application.put_env(:phoenix_test_only, :test_gate, true)
      assert PhoenixTestOnly.should_emit?(Kernel, otp_app: :phoenix_test_only, key: :test_gate)

      Application.put_env(:phoenix_test_only, :test_gate, false)
      refute PhoenixTestOnly.should_emit?(Kernel, otp_app: :phoenix_test_only, key: :test_gate)

      Application.delete_env(:phoenix_test_only, :test_gate)
      refute PhoenixTestOnly.should_emit?(Kernel, otp_app: :phoenix_test_only, key: :test_gate)
    end

    test "returns false when module missing even if config is truthy" do
      Application.put_env(:phoenix_test_only, :test_gate, true)

      refute PhoenixTestOnly.should_emit?(
               NoSuchModule.AtAll,
               otp_app: :phoenix_test_only,
               key: :test_gate
             )

      Application.delete_env(:phoenix_test_only, :test_gate)
    end
  end
end
