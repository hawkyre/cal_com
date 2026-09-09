defmodule CalCom.OAuthCaptureTest do
  use ExUnit.Case, async: true

  alias CalCom.{Call, Codec, Response, ResponseParser}

  @fixtures Path.expand("../support/fixtures/cal_com", __DIR__)

  for number <- [1, 3, 4, 5, 6, 7] do
    @number number
    test "recorded OAuth attempt #{@number} retains the complete typed response" do
      capture = fixture(@number)

      {:ok, call} =
        Call.parse(%{
          "operation" => capture["operation"],
          "input" => capture["request"]["params"]
        })

      response = %Response{status: capture["http_status"], body: capture["body"]}
      assert ResponseParser.classify(response) == :ok
      assert {:ok, output} = call.operation.module.parse_response(response)
      assert Codec.wire(output.value) == Jason.decode!(response.body)
    end
  end

  test "recorded token refresh preserves the scope and account while rotating tokens" do
    issued = body(7)
    refreshed = body(4)
    assert issued["scope"] == "PROFILE_READ"
    assert refreshed["scope"] == issued["scope"]
    assert refreshed["access_token"] != issued["access_token"]
    assert refreshed["refresh_token"] != issued["refresh_token"]
    assert body(3)["data"]["id"] == body(5)["data"]["id"]
  end

  @spec fixture(pos_integer()) :: map()
  defp fixture(number) do
    suffix = number |> Integer.to_string() |> String.pad_leading(2, "0")
    @fixtures |> Path.join("oauth_#{suffix}.json") |> File.read!() |> Jason.decode!()
  end

  @spec body(pos_integer()) :: map()
  defp body(number), do: number |> fixture() |> Map.fetch!("body") |> Jason.decode!()
end
