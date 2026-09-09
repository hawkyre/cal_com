defmodule CalCom.CaptureTest do
  use ExUnit.Case, async: true

  alias CalCom.{Call, Codec, Context, Credentials, Pagination, Registry, Response, ResponseParser}
  alias CalCom.WebhookPayloads

  @fixtures Path.expand("../support/fixtures/cal_com", __DIR__)
  @cases @fixtures |> Path.join("live_index.json") |> File.read!() |> Jason.decode!()
  @webhooks @fixtures |> Path.join("webhook_*.json") |> Path.wildcard()

  test "recorded booking pages retain their filters and terminate" do
    operation = Registry.find("GET /v2/bookings")
    params = fixture("capture_117.json")["request"]["params"]
    second_params = fixture("capture_125.json")["request"]["params"]
    {:ok, call} = Call.parse(%{"operation" => operation.id, "params" => params})
    request = Pagination.first(operation.key, context(call), nil)

    assert %CalCom.Request{} =
             following = Pagination.next(operation.key, response("capture_117.json"), request)

    assert Codec.object_wire(following.private.cal_com.call.input) == second_params
    assert second_params["query"]["limit"] == params["query"]["limit"]
    assert second_params["query"]["status"] == params["query"]["status"]
    assert Pagination.next(operation.key, response("capture_125.json"), following) == nil
  end

  for path <- @webhooks do
    @webhook path |> File.read!() |> Jason.decode!()
    test "recorded webhook #{@webhook["file"]} retains the complete redacted payload" do
      raw = Jason.decode!(@webhook["body"])
      assert {:ok, value} = WebhookPayloads.parse(raw)
      assert Codec.wire(value) == raw
      assert raw["triggerEvent"] == @webhook["event"]
      assert raw["payload"]["uid"] == @webhook["booking_uid"]
      assert @webhook["version"] == "2026-07-27"

      for check <-
            ~w(signature_verified parsed matched_booking tampering_rejected
                       wrong_secret_rejected duplicate_signature_rejected duplicate_version_rejected) do
        assert @webhook[check] == true
      end
    end
  end

  test "recorded history pages produce a continuation and then terminate" do
    operation = Registry.find("GET /v2/event-types/{eventTypeId}/history")
    first_fixture = fixture("capture_077.json")
    first_response = response("capture_077.json")
    second_response = response("capture_078.json")
    cursor = Jason.decode!(first_response.body)["pagination"]["nextCursor"]

    {:ok, first_call} =
      Call.parse(%{"operation" => operation.id, "params" => first_fixture["request"]["params"]})

    first = Pagination.first(operation.key, context(first_call), nil)
    assert %CalCom.Request{} = following = Pagination.next(operation.key, first_response, first)
    original_params = first_fixture["request"]["params"]
    following_params = Codec.object_wire(following.private.cal_com.call.input)
    assert following_params["query"] == Map.put(original_params["query"], "cursor", cursor)
    assert following_params["path"] == original_params["path"]

    # Replay a real terminal body; the live caller used a larger second page.
    assert fixture("capture_078.json")["request"]["params"]["query"]["limit"] == 50
    assert Pagination.next(operation.key, second_response, following) == nil
  end

  @spec fixture(String.t()) :: map()
  defp fixture(file), do: @fixtures |> Path.join(file) |> File.read!() |> Jason.decode!()

  @spec response(String.t()) :: Response.t()
  defp response(file) do
    capture = fixture(file)
    %Response{status: capture["http_status"], body: capture["body"]}
  end

  @spec context(Call.t()) :: Context.t()
  defp context(call) do
    %Context{
      call: call,
      credentials: %Credentials{kind: :api_key, token: "unvalidated-capture-token"}
    }
  end

  for capture <- @cases do
    @capture capture
    test "recorded #{@capture["capture"]} #{@capture["operation"]} retains its complete payload" do
      response = response(@capture["capture"])
      assert response.status == @capture["status"]
      operation = Registry.find(@capture["operation"])

      if response.status in 200..299 do
        assert ResponseParser.classify(response) == :ok
        assert {:ok, output} = operation.module.parse_response(response)
        assert Codec.wire(output.value) == Jason.decode!(response.body)
      else
        assert {:error, %CalCom.Error{} = error} = ResponseParser.classify(response)
        assert operation.module.parse_response(response) == {:error, error}
      end
    end
  end
end
