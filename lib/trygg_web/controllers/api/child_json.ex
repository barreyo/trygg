defmodule TryggWeb.Api.ChildJSON do
  alias Trygg.Families.Child

  def index(%{children: children}), do: %{data: Enum.map(children, &data/1)}

  def show(%{child: child}), do: %{data: data(child)}

  @doc false
  def data(%Child{} = child) do
    %{
      id: child.id,
      name: child.name,
      birth_date: child.birth_date,
      expected_birth_date: child.expected_birth_date,
      sex: child.sex,
      timezone: child.timezone,
      # What the calling token may do for this child.
      role: child.role
    }
  end
end
