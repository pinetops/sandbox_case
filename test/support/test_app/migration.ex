defmodule SandboxCase.TestApp.Migration do
  use Ecto.Migration

  def change do
    create table(:items) do
      add(:name, :string)
    end
  end
end
