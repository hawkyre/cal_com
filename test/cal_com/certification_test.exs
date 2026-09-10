defmodule CalCom.CertificationTest do
  use ExUnit.Case, async: true

  alias CalCom.Registry

  @source Path.expand("../../source", __DIR__)
  @statuses ~w(verified refused unreachable declined)

  # The certification file is the release gate: it says, per operation, what a
  # live call answered. These assertions keep it from rotting — an operation
  # added without being exercised, a verdict that lost its reason, or an open
  # shape mismatch all fail the suite rather than sitting quietly in a JSON file.
  setup do
    {:ok, report: read("certification.json")}
  end

  test "every operation the registry has carries exactly one verdict", %{report: report} do
    operations = report["operations"]
    registry = Registry.all() |> Enum.map(& &1.id) |> Enum.sort()

    assert Enum.sort(Map.keys(operations)) == registry

    # The comparison must bite: one operation short is not the registry.
    [_first | incomplete] = registry
    refute Enum.sort(incomplete) == registry
  end

  test "no operation is left without a verdict", %{report: report} do
    blank =
      for {id, verdict} <- report["operations"],
          verdict["status"] not in @statuses,
          do: {id, verdict}

    assert blank == [],
           "these operations carry no verdict: #{inspect(Enum.map(blank, &elem(&1, 0)))}"
  end

  test "a declined operation says why it could not be exercised", %{report: report} do
    for {id, verdict} <- report["operations"], verdict["status"] == "declined" do
      assert is_binary(verdict["reason"]) and byte_size(verdict["reason"]) > 20,
             "#{id} is declined without a usable reason"
    end
  end

  test "an unreachable operation carries the answer its probe got", %{report: report} do
    for {id, verdict} <- report["operations"], verdict["status"] == "unreachable" do
      assert is_binary(verdict["reason"]),
             "#{id} is unreachable without saying which id is missing"

      assert %{"status" => probe} = verdict["probe"],
             "#{id} is unreachable without the probe that called it: #{inspect(verdict["probe"])}"

      assert probe in @statuses
    end
  end

  test "a verified operation names a 2xx, and a refused one names a status", %{report: report} do
    for {id, verdict} <- report["operations"] do
      case verdict["status"] do
        "verified" ->
          assert verdict["http"] in 200..299,
                 "#{id} is verified without a 2xx: #{inspect(verdict["http"])}"

        "refused" ->
          assert is_integer(verdict["http"]), "#{id} is refused without a status"
          refute verdict["http"] in 200..299, "#{id} is refused with a 2xx"

        _other ->
          :ok
      end
    end
  end

  test "no live response is refused by its own contract", %{report: report} do
    mismatches =
      for {id, verdict} <- report["operations"], verdict["status"] == "shape_mismatch", do: id

    assert mismatches == [], "the contract refuses live responses for: #{inspect(mismatches)}"
  end

  test "the report says which account and when", %{report: report} do
    assert %{"user_id" => user_id, "organization_id" => organization_id} = report["account"]
    assert is_integer(user_id) and is_integer(organization_id)
    assert is_binary(report["generated_at"])
  end

  @spec read(String.t()) :: map()
  defp read(file), do: @source |> Path.join(file) |> File.read!() |> Jason.decode!()
end
