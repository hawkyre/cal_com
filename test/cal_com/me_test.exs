defmodule CalCom.MeTest do
  use ExUnit.Case, async: true

  alias CalCom.Credentials
  alias CalCom.Entities.{GetMeOutput, MeOutput, ResultMeControllerGetMe200}
  alias CalCom.Operations.MeControllerGetMe
  alias CalCom.Response

  # Redacted capture of a real `GET /v2/me` against the isolated test account,
  # recorded 2026-09-08. Field names, nulls and structure are retained.
  @capture """
  {
    "status": "success",
    "data": {
      "id": 3209949,
      "email": "redacted@example.invalid",
      "name": "redacted",
      "avatarUrl": null,
      "bio": "",
      "timeFormat": 12,
      "defaultScheduleId": 2335882,
      "weekStart": "Sunday",
      "timeZone": "America/Los_Angeles",
      "username": "redacted-test",
      "locale": null,
      "organizationId": null
    }
  }
  """

  test "an API key builds the fixed GET /v2/me request" do
    {:ok, input} = MeControllerGetMe.parse_input(%{})

    assert {:ok, request} =
             MeControllerGetMe.request(input, %Credentials{kind: :api_key, token: "cal_test"})

    assert request.method == :get
    assert request.url == "https://api.cal.com/v2/me"
    assert request.headers == [{"authorization", "Bearer cal_test"}]
    assert request.body == nil
  end

  test "no credentials leave the request unauthenticated" do
    {:ok, input} = MeControllerGetMe.parse_input(%{})

    assert {:ok, request} = MeControllerGetMe.request(input, %Credentials{})

    assert request.headers == []
  end

  test "an unknown input key is refused at the boundary" do
    assert {:error, %CalCom.Error{reason: :invalid_body, payload: "additionalProperties"}} =
             MeControllerGetMe.parse_input(%{"unexpected" => true})
  end

  test "the recorded capture parses into the typed result" do
    assert {:ok, %ResultMeControllerGetMe200{value: %GetMeOutput{status: :success, data: data}}} =
             MeControllerGetMe.parse_response(%Response{status: 200, body: @capture})

    assert %MeOutput{} = data
    assert data.id == 3_209_949
    assert data.email == "redacted@example.invalid"
    assert data.avatar_url == nil
    assert data.bio == ""
    assert data.time_format == 12
    assert data.week_start == "Sunday"
    assert data.time_zone == "America/Los_Angeles"
    assert data.locale == nil
    assert data.organization_id == nil
  end

  test "a wrong key is a closed unauthorized reason with the payload kept" do
    body = ~s({"message":"Unauthorized"})

    assert {:error, %CalCom.Error{reason: :unauthorized, payload: %{"message" => "Unauthorized"}}} =
             MeControllerGetMe.parse_response(%Response{status: 401, body: body})
  end

  test "a rate limit carries the resume instant" do
    response = %Response{
      status: 429,
      headers: %{"retry-after" => ["30"]},
      body: ~s({"message":"rate limited"})
    }

    assert {:error, %CalCom.Error{reason: {:rate_limited, :provider, %DateTime{}}}} =
             MeControllerGetMe.parse_response(response)
  end
end
