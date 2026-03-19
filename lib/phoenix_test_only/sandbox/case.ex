defmodule PhoenixTestOnly.Sandbox.Case do
  @moduledoc """
  ExUnit case template that checks out all configured sandboxes
  and checks them back in on exit.

      use PhoenixTestOnly.Sandbox.Case

  Adds `%{sandbox_tokens: tokens}` to the test context. The Ecto
  metadata (for browser test sessions) is available via:

      PhoenixTestOnly.Sandbox.ecto_metadata(context.sandbox_tokens)
  """

  use ExUnit.CaseTemplate

  setup context do
    tokens = PhoenixTestOnly.Sandbox.checkout(async?: context[:async] || false)

    on_exit(fn ->
      PhoenixTestOnly.Sandbox.checkin(tokens)
    end)

    %{sandbox_tokens: tokens}
  end
end
