defmodule CalCom.CodecTest do
  use ExUnit.Case, async: true

  alias CalCom.{Codec, RequestBuilder, Rule}
  alias CalCom.Test.Patch

  test "PATCH encoding preserves omitted, null, false, zero, and empty list values" do
    assert {:ok, absent} = Patch.parse(%{})
    assert Patch.encode(absent) == %{}
    raw = %{"title" => nil, "enabled" => false, "count" => 0, "items" => []}
    assert {:ok, value} = Patch.parse(raw)
    assert Patch.encode(value) == raw
    assert MapSet.member?(value.provided, :title)
    assert {:error, %CalCom.Error{}} = Patch.parse(%{"enabled" => nil})
    assert {:error, %CalCom.Error{}} = Patch.parse(%{"items" => [1, "invalid", 3]})
    assert {:error, %CalCom.Error{}} = Patch.parse(%{"extra" => true})
  end

  test "source constraints and unions reject invalid values without dropping data" do
    assert :error = Codec.value(%Rule{kind: :integer, minimum: 1}, 0)
    assert :error = Codec.value(%Rule{kind: :date}, "not-a-date")
    assert :error = Codec.value(%Rule{kind: :datetime}, "2026-01-01")

    assert :error =
             Codec.value(%Rule{kind: {:array, %Rule{kind: :integer}}, unique_items: true}, [1, 1])

    assert :error =
             Codec.value(%Rule{kind: {:one_of, [%Rule{kind: :integer}, %Rule{kind: :number}]}}, 1)

    assert {:ok, :accepted} =
             Codec.value(%Rule{kind: {:enum, [{"accepted", :accepted}]}}, "accepted")

    assert Codec.wire(:accepted) == "accepted"
  end

  test "query encoders preserve comma lists, repeated values, and calendar brackets" do
    assert RequestBuilder.query_pairs(%{"status" => ["upcoming", "past"]}, "/v2/bookings") ==
             [{"status", "upcoming,past"}]

    assert RequestBuilder.query_pairs(
             %{"emails" => ["a@kithe.invalid", "b@kithe.invalid"]},
             "/v2/organizations/{orgId}/users"
           ) ==
             [{"emails", "a@kithe.invalid"}, {"emails", "b@kithe.invalid"}]

    assert RequestBuilder.query_pairs(
             %{"calendarsToLoad" => [%{"credentialId" => 1}]},
             "/v2/calendars/busy-times"
           ) ==
             [{"calendarsToLoad[0][credentialId]", "1"}]
  end

  test "raw payloads redact Cal secret headers and OAuth codes at every depth" do
    raw = %{
      "headers" => %{"x-cal-secret-key" => "secret"},
      "body" => %{"code" => "secret", "code_verifier" => "secret", "client_id" => "public"}
    }

    assert Codec.redact(raw) == %{"headers" => %{}, "body" => %{"client_id" => "public"}}
  end
end
