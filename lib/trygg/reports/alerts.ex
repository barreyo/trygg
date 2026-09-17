defmodule Trygg.Reports.Alerts do
  @moduledoc """
  Turns the report summaries into a short, ordered list of plain-language
  cards for the Home and Reports screens.

  Each alert is `%{id, severity, title, detail, link}` where `severity` is
  `:warning | :notice | :info`, `id` is stable (safe for DOM ids and tests)
  and `link` is `:vitals | :reports | nil`.

  Copy rules: no diagnoses, no "regression", no "dehydrated", no "underfed".
  Say what changed, what the usual is, and where the threshold comes from.
  """

  alias Trygg.Growth.Percentiles
  alias Trygg.Reports.Shifts
  alias Trygg.Units

  @severity_rank %{warning: 0, notice: 1, info: 2}

  @doc """
  `summaries` is a map with `:feeding`, `:diapers`, `:shifts` and `:growth`
  (any may be `nil`). Options: `:unit_system` for volumes.
  """
  def build(summaries, opts \\ []) do
    units = Keyword.get(opts, :unit_system, :metric)

    [
      hydration(summaries[:diapers]),
      feeding_check(summaries[:shifts], summaries[:diapers]),
      intake(summaries[:feeding], units),
      sleep_shift(summaries[:shifts]),
      growth_burst(summaries[:shifts]),
      growth(summaries[:growth])
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&@severity_rank[&1.severity])
  end

  @doc "The one-line disclaimer shown under any alert list."
  def disclaimer, do: "Not medical advice — call your pediatrician if you're worried."

  ## Hydration ---------------------------------------------------------------

  defp hydration(nil), do: []

  defp hydration(diapers) do
    Enum.map(diapers.flags, fn
      :no_wet_6h ->
        hours = div(diapers.dry_seconds || 0, 3600)

        alert(
          "no-wet-diaper",
          :warning,
          "No wet diaper in #{hours}h",
          "Six or more dry hours is one of the signs pediatricians ask about (AAP). " <>
            "Offer a feed and keep an eye on it."
        )

      :low_wet_pace ->
        expected = round(diapers.today.expected_wet_by_now)

        alert(
          "low-wet-pace",
          :notice,
          "Fewer wet diapers than usual today",
          "#{diapers.today.wet} so far — by this time they usually have about #{expected}."
        )

      :low_wet_day ->
        y = diapers.yesterday

        usual =
          case diapers.baseline.wet.median do
            nil -> ""
            med -> " (their usual is about #{round(med)})"
          end

        alert(
          "low-wet-day",
          :warning,
          "Only #{y.wet} wet #{plural(y.wet, "diaper")} yesterday",
          "Fewer than #{diapers.min_wet} in a day is below the usual floor for their age#{usual}."
        )
    end)
  end

  ## Feeding -----------------------------------------------------------------

  defp feeding_check(nil, _diapers), do: nil

  defp feeding_check(%{feeding: findings}, diapers) do
    up = Enum.find(findings, &(&1.direction == :up))
    down = Enum.find(findings, &(&1.direction == :down and &1.metric == :feeds))
    hydration_flags? = diapers && diapers.flags != []

    cond do
      up && hydration_flags? ->
        alert(
          "feeding-check",
          :notice,
          "Feeding more, but fewer wet diapers",
          "#{finding_phrase(up)}. With wet diapers also down, it's worth a call to your pediatrician if it continues.",
          :reports
        )

      up ->
        alert(
          "feeding-check",
          :info,
          "Eating more than usual",
          "#{finding_phrase(up)}, with normal wet diapers — that usually means growth or a cluster-feeding stretch, not a problem.",
          :reports
        )

      down ->
        alert(
          "feeding-check",
          :notice,
          "Feeding less than usual",
          "#{finding_phrase(down)}. Fine if they seem content and diapers are normal; mention it if it lasts.",
          :reports
        )

      true ->
        nil
    end
  end

  defp finding_phrase(%{metric: :feeds} = f) do
    "About #{round(f.recent_median)} feeds a day the last few days vs their usual #{round(f.baseline_median)}"
  end

  defp finding_phrase(%{metric: :feed_ml} = f) do
    pct = round(abs(f.delta) / max(f.baseline_median, 1) * 100)
    dir = if f.direction == :up, do: "up", else: "down"
    "Daily volume #{dir} about #{pct}% the last few days"
  end

  defp intake(nil, _units), do: nil
  defp intake(%{intake: nil}, _units), do: nil

  defp intake(%{intake: %{status: :below} = intake}, units) do
    alert(
      "intake-below-guide",
      :info,
      "Intake below the usual guide",
      "Averaging #{Units.format(intake.avg_ml, :volume, units)} a day over the last #{intake.avg_days} " <>
        "#{plural(intake.avg_days, "day")} (#{Units.format_rate_per_kg(intake.ml_per_kg, units)}). " <>
        "The guide for their age is #{Units.format_rate_per_kg_range(intake.guide_per_kg, units)}/day (AAP). " <>
        "Babies vary; growth is the better check.",
      :vitals
    )
  end

  defp intake(_feeding, _units), do: nil

  ## Sleep shift -------------------------------------------------------------

  defp sleep_shift(nil), do: nil
  defp sleep_shift(%{sleep: []}), do: nil

  defp sleep_shift(%{sleep: findings}) do
    worse? = Enum.any?(findings, &worse?/1)
    lines = Enum.map_join(findings, " · ", &shift_line/1)

    alert(
      "sleep-shift",
      if(worse?, do: :notice, else: :info),
      if(worse?, do: "Sleep shift", else: "Sleep is settling"),
      lines <>
        if(worse?,
          do:
            ". Shifts like this often come with new motor skills, teething or a cold, and usually settle within 1–3 weeks.",
          else: ". Compared with the two weeks before."
        ),
      :reports
    )
  end

  defp worse?(%{metric: :night_wakings, direction: :up}), do: true

  defp worse?(%{metric: metric, direction: :down})
       when metric in [:overnight_sleep, :total_sleep], do: true

  defp worse?(_), do: false

  defp shift_line(%{metric: metric} = f) do
    dir = if f.direction == :up, do: "up", else: "down"

    if Shifts.duration_metric?(metric) do
      "#{Shifts.metric_label(metric)} #{dir}: #{duration(f.recent_median)} vs usual #{duration(f.baseline_median)}"
    else
      "#{Shifts.metric_label(metric)} #{dir}: ~#{round(f.recent_median)} vs usual ~#{round(f.baseline_median)}"
    end
  end

  ## Growth burst -------------------------------------------------------------

  defp growth_burst(nil), do: nil
  defp growth_burst(%{growth_burst: %{active?: false}}), do: nil

  defp growth_burst(%{growth_burst: burst}) do
    extra =
      cond do
        burst.sleep_days >= 1 and burst.extra_sleep_seconds > 0 ->
          "about #{duration(burst.extra_sleep_seconds)} more sleep than usual"

        true ->
          "about #{round(burst.extra_naps)} more #{plural(round(burst.extra_naps), "nap")} than usual"
      end

    feed = if burst.feed_up?, do: " and roughly #{round(burst.feed_pct)}% more milk", else: ""

    alert(
      "growth-burst",
      :info,
      "Sleeping more than usual",
      "#{String.capitalize(extra)}#{feed} on #{Calendar.strftime(burst.on, "%a %-d %b")}. " <>
        "In one diary study (Lampl & Johnson, 2011) bursts like this preceded a growth spurt in length by 0–4 days. " <>
        "Good moment to log a measurement.",
      :vitals
    )
  end

  ## Growth -------------------------------------------------------------------

  defp growth(nil), do: []

  defp growth(growth) do
    [newborn_alerts(growth.newborn), percentile_alert(growth.velocity)]
  end

  defp newborn_alerts(nil), do: []

  defp newborn_alerts(newborn) do
    [
      if newborn.loss_flag? do
        alert(
          "newborn-weight-loss",
          :warning,
          "Down #{Float.round(newborn.loss_pct, 1)}% from birth weight",
          "Losing some weight in the first days is normal; more than 10% is worth a check-in with your pediatrician or lactation consultant.",
          :vitals
        )
      end,
      if newborn.regain_overdue? do
        alert(
          "newborn-regain",
          :notice,
          "Not back to birth weight yet",
          "Most babies regain it by about day 14; the latest reading is #{round(newborn.latest_pct_of_birth)}% of birth weight. Worth mentioning at the next visit.",
          :vitals
        )
      end
    ]
  end

  defp percentile_alert(nil), do: nil

  defp percentile_alert(%{percentile_drop?: true} = v) do
    alert(
      "percentile-drop",
      :notice,
      "Weight percentile moved down",
      "From about the #{Percentiles.format_percentile(v.percentile_prev)} to the #{Percentiles.format_percentile(v.percentile_now)} over #{v.days} days. " <>
        "A drop across a major percentile band is worth mentioning at the next visit.",
      :vitals
    )
  end

  defp percentile_alert(_), do: nil

  ## Helpers -------------------------------------------------------------------

  defp alert(id, severity, title, detail, link \\ nil) do
    %{id: id, severity: severity, title: title, detail: detail, link: link}
  end

  defp duration(seconds) when is_number(seconds) do
    total = round(seconds)
    h = div(total, 3600)
    m = rem(div(total, 60), 60)

    cond do
      h > 0 and m > 0 -> "#{h}h #{m}m"
      h > 0 -> "#{h}h"
      true -> "#{m}m"
    end
  end

  defp plural(1, word), do: word
  defp plural(_, word), do: word <> "s"
end
