defmodule Trygg.Families.NotAuthorizedError do
  @moduledoc """
  Raised when a caller's role for a child is insufficient for the attempted
  action. Rendered as an HTTP 403.
  """
  defexception [:role, :required, plug_status: 403]

  @impl true
  def message(%{role: nil, required: required}) do
    "not a caregiver of this child (requires #{required})"
  end

  def message(%{role: role, required: required}) do
    "role #{role} is not permitted here (requires #{required})"
  end
end
