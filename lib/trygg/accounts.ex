defmodule Trygg.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias Trygg.Repo

  alias Trygg.Accounts.{User, UserToken, UserNotifier}

  ## PubSub ----------------------------------------------------------------

  @doc "Topic for realtime messages private to one user (across their devices)."
  def user_topic(user_id), do: "user:#{user_id}"

  @doc "Subscribe the calling process to a user's private realtime topic."
  def subscribe_user(user_id) do
    Phoenix.PubSub.subscribe(Trygg.PubSub, user_topic(user_id))
  end

  @doc "Broadcast a realtime message to every live view open for a user."
  def broadcast_user(user_id, message) do
    Phoenix.PubSub.broadcast(Trygg.PubSub, user_topic(user_id), message)
  end

  ## Database getters

  @doc """
  Gets a user by email.

  ## Examples

      iex> get_user_by_email("foo@example.com")
      %User{}

      iex> get_user_by_email("unknown@example.com")
      nil

  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  ## User registration

  @doc """
  Registers a user.

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for registering a user.
  """
  def change_user_registration(user \\ %User{}, attrs \\ %{}) do
    User.registration_changeset(user, attrs, validate_unique: false)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user's name.
  """
  def change_user_name(user, attrs \\ %{}) do
    User.name_changeset(user, attrs)
  end

  @doc """
  Updates the user's name.
  """
  def update_user_name(%User{} = user, attrs) do
    with {:ok, user} <- user |> User.name_changeset(attrs) |> Repo.update() do
      broadcast_user(user.id, {:user_updated, user})
      {:ok, user}
    end
  end

  ## Settings

  @doc """
  Checks whether the user is in sudo mode.

  The user is in sudo mode when the last authentication was done no further
  than 20 minutes ago. The limit can be given as second argument in minutes.
  """
  def sudo_mode?(user, minutes \\ -20)

  def sudo_mode?(%User{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_user, _minutes), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  See `Trygg.Accounts.User.email_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_email(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_email(user, attrs \\ %{}, opts \\ []) do
    User.email_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  """
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
           %UserToken{sent_to: email} <- Repo.one(query),
           {:ok, user} <- Repo.update(User.email_changeset(user, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(from(UserToken, where: [user_id: ^user.id, context: ^context])) do
        broadcast_user(user.id, {:user_updated, user})
        {:ok, user}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user's app preferences.
  """
  def change_user_settings(user, attrs \\ %{}) do
    User.settings_changeset(user, attrs)
  end

  @doc """
  Updates the user's app preferences (measurement units, ...).
  """
  def update_user_settings(%User{} = user, attrs) do
    with {:ok, user} <- user |> User.settings_changeset(attrs) |> Repo.update() do
      broadcast_user(user.id, {:user_updated, user})
      {:ok, user}
    end
  end

  @doc """
  Remembers the child this caregiver is currently looking at (see
  `users.last_child_id`), so `/` reopens it rather than the newest child.

  Fire-and-forget UI state: a single primary-key `UPDATE`, no `updated_at` bump
  and no `{:user_updated}` broadcast. No-ops when the value is unchanged.
  """
  def put_last_child(%User{last_child_id: same}, child_id) when same == child_id, do: :ok

  def put_last_child(%User{id: user_id}, child_id) do
    from(u in User, where: u.id == ^user_id)
    |> Repo.update_all(set: [last_child_id: child_id])

    :ok
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc """
  Gets the user with the given magic link token.
  """
  def get_user_by_magic_link_token(token) do
    with {:ok, query} <- UserToken.verify_magic_link_token_query(token),
         {user, _token} <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Logs the user in by magic link.

  Two cases to consider:

  1. The user has already confirmed their email. They are logged in and the
     magic link is expired.

  2. The user has not confirmed their email. They get confirmed, logged in, and
     all their tokens - including session ones - are expired.
  """
  def login_user_by_magic_link(token) do
    {:ok, query} = UserToken.verify_magic_link_token_query(token)
    finish_login(Repo.one(query))
  end

  @doc """
  Logs the user in with the numeric code from the login email.

  Same semantics as `login_user_by_magic_link/1`: the code is single use and
  redeeming it also invalidates the magic link it was sent with (and vice
  versa). The code is matched against the user with the given email only, so a
  guessed code is useless without also knowing the address it was sent to.
  """
  def login_user_by_code(email, code) when is_binary(email) and is_binary(code) do
    with %User{} = user <- get_user_by_email(email),
         {:ok, code} <- normalize_login_code(code),
         {:ok, query} <- UserToken.verify_login_code_query(user, code) do
      finish_login(Repo.one(query))
    else
      _ -> {:error, :not_found}
    end
  end

  # Accepts what people actually type: "123 456", "123-456", trailing space.
  defp normalize_login_code(code) do
    digits = String.replace(code, ~r/\D/, "")

    if String.length(digits) == UserToken.login_code_digits() do
      {:ok, digits}
    else
      :error
    end
  end

  # Shared tail of magic-link and code logins. Unconfirmed users get confirmed
  # and *all* their tokens dropped; confirmed users only lose their pending
  # login tokens (link + code), never their other device sessions.
  defp finish_login({%User{confirmed_at: nil} = user, _token}) do
    user
    |> User.confirm_changeset()
    |> update_user_and_delete_all_tokens()
  end

  defp finish_login({%User{} = user, _token}) do
    Repo.delete_all(pending_login_tokens_query(user))
    {:ok, {user, []}}
  end

  defp finish_login(nil), do: {:error, :not_found}

  defp pending_login_tokens_query(user) do
    contexts = ["login", UserToken.login_code_context()]
    from t in UserToken, where: t.user_id == ^user.id and t.context in ^contexts
  end

  @doc ~S"""
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_user_update_email_instructions(user, current_email, &url(~p"/users/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Delivers the login email to the given user: a magic link plus a short code
  that can be typed into an installed (home screen) app where the link can't
  be opened.

  Only the most recent code is valid; issuing a new one revokes earlier ones.
  """
  def deliver_login_instructions(%User{} = user, magic_link_url_fun)
      when is_function(magic_link_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "login")
    {code, code_token} = UserToken.build_login_code(user)
    code_context = UserToken.login_code_context()

    {:ok, _} =
      Repo.transact(fn ->
        Repo.delete_all(from(t in UserToken, where: [user_id: ^user.id, context: ^code_context]))
        Repo.insert!(user_token)
        Repo.insert!(code_token)
        {:ok, :sent}
      end)

    UserNotifier.deliver_login_instructions(user, magic_link_url_fun.(encoded_token), code)
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  ## Token helper

  defp update_user_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end
end
