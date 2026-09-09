defmodule CalCom.WebhookTest do
  use ExUnit.Case, async: true

  alias CalCom.Webhook
  alias CalCom.WebhookPayloads

  @body ~s({"triggerEvent":"BOOKING_CREATED"})
  @secret "unvalidated-offline-test-secret"
  @version "2026-07-27"

  test "HMAC covers the exact raw bytes and requires a secret" do
    headers = signature_headers(@body, @secret)
    assert Webhook.verify(@body, headers, secret: @secret)

    refute Webhook.verify(@body, [{"x-CAL-signature-256", signature(@body, @secret)} | headers],
             secret: @secret
           )

    refute Webhook.verify(@body <> " ", headers, secret: @secret)
    refute Webhook.verify(@body, headers, [])
    refute Webhook.verify(@body, [{"x-cal-signature-256", "invalid"}], secret: @secret)
  end

  test "a signed delivery parses into its typed payload and version" do
    headers = [{"x-cal-webhook-version", @version} | signature_headers(@body, @secret)]

    assert {:ok, %Webhook{event: "BOOKING_CREATED", version: @version}} =
             Webhook.parse(@body, headers, secret: @secret)
  end

  test "a repeated version header is refused" do
    headers = [{"x-cal-webhook-version", @version} | signature_headers(@body, @secret)]

    assert {:error, %CalCom.Error{reason: :invalid_body}} =
             Webhook.parse(@body, [{"X-CAL-WEBHOOK-VERSION", @version} | headers],
               secret: @secret
             )
  end

  test "a repeated signature header is unauthorized" do
    headers = [{"x-cal-webhook-version", @version} | signature_headers(@body, @secret)]

    assert {:error, %CalCom.Error{reason: :unauthorized}} =
             Webhook.parse(
               @body,
               [{"x-cal-signature-256", signature(@body, @secret)} | headers],
               secret: @secret
             )
  end

  test "a missing version header is refused" do
    assert {:error, %CalCom.Error{reason: :invalid_body}} =
             Webhook.parse(@body, signature_headers(@body, @secret), secret: @secret)
  end

  test "a tampered body is unauthorized" do
    headers = [{"x-cal-webhook-version", @version} | signature_headers(@body, @secret)]

    assert {:error, %CalCom.Error{reason: :unauthorized}} =
             Webhook.parse(@body <> " ", headers, secret: @secret)
  end

  test "an unsupported version and an unknown trigger are refused" do
    legacy = [{"x-cal-webhook-version", "1999-01-01"} | signature_headers(@body, @secret)]

    assert {:error, %CalCom.Error{reason: :invalid_body}} =
             Webhook.parse(@body, legacy, secret: @secret)

    assert {:error, %CalCom.Error{reason: :invalid_body}} =
             WebhookPayloads.parse(%{"triggerEvent" => "NOT_A_CAL_EVENT"})
  end

  @spec signature_headers(binary(), binary()) :: [{String.t(), String.t()}]
  defp signature_headers(body, secret), do: [{"X-Cal-Signature-256", signature(body, secret)}]

  @spec signature(binary(), binary()) :: String.t()
  defp signature(body, secret),
    do: Base.encode16(:crypto.mac(:hmac, :sha256, secret, body), case: :lower)
end
