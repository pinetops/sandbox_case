defmodule SandboxCase.Sandbox.Case do
  @moduledoc """
  ExUnit case template that checks out all configured sandboxes
  and checks them back in on exit.

      use SandboxCase.Sandbox.Case

  Adds `%{sandbox_tokens: tokens}` to the test context. The Ecto
  metadata (for browser test sessions) is available via:

      SandboxCase.Sandbox.ecto_metadata(context.sandbox_tokens)
  """

  use ExUnit.CaseTemplate

  setup context do
    sandbox = SandboxCase.Sandbox.checkout(async?: context[:async] || false)

    on_exit(fn ->
      SandboxCase.Sandbox.checkin(sandbox)
    end)

    %{sandbox: sandbox}
  end
end
