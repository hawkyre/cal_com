defmodule CalCom.CancellationTest do
  use ExUnit.Case, async: true

  alias CalCom.{Codec, Credentials, Error, Response}
  alias CalCom.Operations.BookingsController20260225CancelBooking, as: Cancel

  @fixtures Path.expand("../support/fixtures/cal_com", __DIR__)

  test "ordinary cancellation omits an absent reason and retains occurrence selection" do
    body = %{"cancelSubsequentBookings" => false}
    assert {:ok, input} = parse(body)
    assert input.body.cancel_subsequent_bookings == false
    assert input.body.cancellation_reason == nil
    assert request_body(input) == body
  end

  test "explicit reasons retain their whitespace and empty values" do
    for reason <- ["", "  Schedule changed.\nPlease contact me tomorrow.  "] do
      body = %{"cancelSubsequentBookings" => false, "cancellationReason" => reason}
      assert {:ok, input} = parse(body)
      assert input.body.cancellation_reason == reason
      assert request_body(input) == body
    end
  end

  test "ordinary cancellation retains omitted and enabled recurrence selection" do
    for body <- [%{}, %{"cancelSubsequentBookings" => true}] do
      assert {:ok, input} = parse(body)
      assert request_body(input) == body
    end
  end

  test "seated cancellation selects the seat variant without a reason" do
    body = %{"seatUid" => "synthetic-seat"}
    assert {:ok, input} = parse(body)
    assert input.body.seat_uid == "synthetic-seat"
    assert request_body(input) == body
  end

  test "invalid fields cannot pass through another cancellation variant" do
    for body <- [
          %{"seatUid" => 123},
          %{"seatUid" => nil},
          %{"cancelSubsequentBookings" => "false"},
          %{"seatUid" => "synthetic-seat", "cancelSubsequentBookings" => true},
          %{"cancellationReason" => nil}
        ] do
      assert {:error, %Error{}} = parse(body)
    end
  end

  test "recorded ordinary, seated and recurring cancellations retain request and response fields" do
    for name <- ["capture_126.json", "capture_127.json", "capture_128.json"] do
      capture = @fixtures |> Path.join(name) |> File.read!() |> Jason.decode!()
      assert {:ok, input} = Cancel.parse_input(capture["request"]["params"])
      assert Codec.object_wire(input) == capture["request"]["params"]
      response = %Response{status: capture["http_status"], body: capture["body"]}
      assert {:ok, result} = Cancel.parse_response(response)
      assert Codec.wire(result.value) == Jason.decode!(capture["body"])
    end
  end

  @spec parse(map()) :: {:ok, Cancel.input()} | {:error, Error.t()}
  defp parse(body),
    do: Cancel.parse_input(%{"path" => %{"bookingUid" => "synthetic-occurrence"}, "body" => body})

  @spec request_body(Cancel.input()) :: map()
  defp request_body(input) do
    credentials = %Credentials{kind: :oauth, token: "synthetic-token"}
    assert {:ok, request} = Cancel.request(input, credentials)
    assert URI.parse(request.url).path == "/v2/bookings/synthetic-occurrence/cancel"
    Jason.decode!(request.body)
  end
end
