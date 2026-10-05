defmodule Trygg.Push.Notifier do
  @moduledoc """
  Builds the Web Push payloads for app events and fans them out to a user's
  devices via `Trygg.Push.enqueue/2` (one `Trygg.Push.DeliveryWorker` job
  per device).

  The email/banner counterpart is `Trygg.Families.FamilyNotifier`. A weight
  reminder is one event on two channels: `Trygg.Growth.WeightReminders`
  sends the email and calls this for the same caregiver, both covered by that
  caregiver's single `growth_reminder_notifications` row — no separate push
  bookkeeping.
  """
  alias Trygg.Accounts.User
  alias Trygg.Families.Child
  alias Trygg.Push

  @doc """
  Nudges `user`'s devices that `child`'s routine weight check is overdue.
  `status` is a `Trygg.Growth.CheckReminder` map. No-op (returns `:ok`) when
  push is disabled or `user` has no subscriptions.
  """
  @spec deliver_weight_check_reminder(Child.t(), map(), User.t()) :: :ok
  def deliver_weight_check_reminder(%Child{} = child, status, %User{} = user) do
    if Push.enabled?() do
      Push.enqueue(user, %{
        title: "Time to check #{child.name}'s weight",
        body: body(child, status),
        url: "/c/#{child.id}/vitals",
        tag: "weight-check-#{child.id}"
      })
    end

    :ok
  end

  @doc """
  Nudges `user`'s devices that no vitamin D drop has been logged for `child`
  today. Sent by `Trygg.Log.VitaminDReminders`, which does its own once-a-day
  bookkeeping. No-op (returns `:ok`) when push is disabled or `user` has no
  subscriptions.
  """
  @spec deliver_vitamin_d_reminder(Child.t(), User.t()) :: :ok
  def deliver_vitamin_d_reminder(%Child{} = child, %User{} = user) do
    if Push.enabled?() do
      Push.enqueue(user, %{
        title: "Vitamin D drop for #{child.name}",
        body: "No vitamin D drop has been logged today. Tick it when you log the next bottle.",
        url: "/c/#{child.id}",
        tag: "vitamin-d-#{child.id}"
      })
    end

    :ok
  end

  defp body(child, %{never_measured?: true}) do
    "No weight has been logged for #{child.name} yet. Add the first one when you can."
  end

  defp body(child, %{days_since: days}) do
    "It's been #{days} days since #{child.name}'s last weigh-in. A quick check keeps growth on track."
  end
end
