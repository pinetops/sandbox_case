defmodule PhoenixTestOnly.Sandbox.Ecto do
  @moduledoc false
  @behaviour PhoenixTestOnly.Sandbox.Adapter

  @impl true
  def available? do
    Code.ensure_loaded?(Ecto.Adapters.SQL.Sandbox)
  end

  @impl true
  def setup(config) do
    for repo <- repos(config) do
      Ecto.Adapters.SQL.Sandbox.mode(repo, :manual)
    end

    :ok
  end

  @impl true
  def checkout(config) do
    async? = config[:async?] || false

    repos = repos(config)

    for repo <- repos do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(repo)
      unless async?, do: Ecto.Adapters.SQL.Sandbox.mode(repo, {:shared, self()})
    end

    metadata =
      if Code.ensure_loaded?(Phoenix.Ecto.SQL.Sandbox) and repos != [] do
        Phoenix.Ecto.SQL.Sandbox.metadata_for(repos, self())
      end

    %{repos: repos, metadata: metadata}
  end

  @impl true
  def checkin(_token), do: :ok

  defp repos(config) do
    case config[:repos] do
      repos when is_list(repos) -> repos
      nil -> discover_repos(config[:otp_app])
    end
  end

  defp discover_repos(nil), do: []
  defp discover_repos(otp_app), do: Application.get_env(otp_app, :ecto_repos, [])
end
