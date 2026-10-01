defmodule Trygg.Accounts.Scope do
  @moduledoc """
  Defines the scope of the caller to be used throughout the app.

  The `Trygg.Accounts.Scope` allows public interfaces to receive
  information about the caller, such as if the call is initiated from an
  end-user, and if so, which user. Additionally, such a scope can carry fields
  such as "super user" or other privileges for use in authorization checks,
  or to ensure specific code paths can only be accessed for a given scope.

  It is useful for logging as well as for scoping pubsub subscriptions and
  broadcasts when a caller subscribes to an interface or performs a particular
  action.

  Feel free to extend the fields on this struct to fit the needs of
  growing application requirements.
  """

  alias Trygg.Accounts.User
  alias Trygg.Families.ApiToken

  # `api_token` is set when the caller authenticated with an API token rather
  # than a browser session. `Trygg.Families` then confines the scope to the
  # token's family and role.
  defstruct user: nil, child: nil, role: nil, api_token: nil

  @doc """
  Creates a scope for the given user.

  Returns nil if no user is given.
  """
  def for_user(%User{} = user) do
    %__MODULE__{user: user}
  end

  def for_user(nil), do: nil

  @doc """
  Creates a scope for a request authenticated with `token`, acting as the
  `user` who issued it.
  """
  def for_api_token(%User{} = user, %ApiToken{} = token) do
    %__MODULE__{user: user, api_token: token}
  end

  @doc """
  Puts the currently active child and the user's role for that child onto the scope.
  """
  def put_child(%__MODULE__{} = scope, child, role) do
    %{scope | child: child, role: role}
  end
end
