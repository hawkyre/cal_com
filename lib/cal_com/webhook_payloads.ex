defmodule CalCom.WebhookPayloads do
  @moduledoc "Concrete payloads for every documented Cal webhook trigger."
  alias CalCom.{Codec, Entities}
  alias CalCom.Error

  @modules %{
    "BOOKING_CREATED" => Entities.WebhookBookingCreated,
    "BOOKING_CANCELLED" => Entities.WebhookBookingCancelled,
    "BOOKING_RESCHEDULED" => Entities.WebhookBookingRescheduled,
    "BOOKING_REQUESTED" => Entities.WebhookBookingRequested,
    "BOOKING_REJECTED" => Entities.WebhookBookingRejected,
    "BOOKING_PAID" => Entities.WebhookBookingPaid,
    "BOOKING_PAYMENT_INITIATED" => Entities.WebhookBookingPaymentInitiated,
    "BOOKING_NO_SHOW_UPDATED" => Entities.WebhookBookingNoShowUpdated,
    "BOOKING_LOCATION_UPDATED" => Entities.WebhookBookingLocationUpdated,
    "BOOKING_REASSIGNED" => Entities.WebhookBookingReassigned,
    "MEETING_STARTED" => Entities.WebhookMeetingStarted,
    "MEETING_ENDED" => Entities.WebhookMeetingEnded,
    "INSTANT_MEETING" => Entities.WebhookInstantMeeting,
    "INSTANT_MEETING_ACCEPTED" => Entities.WebhookInstantMeetingAccepted,
    "OOO_CREATED" => Entities.WebhookOooCreated,
    "FORM_SUBMITTED" => Entities.WebhookFormSubmitted,
    "FORM_SUBMITTED_NO_EVENT" => Entities.WebhookFormSubmittedNoEvent,
    "AFTER_HOSTS_CAL_VIDEO_NO_SHOW" => Entities.WebhookAfterHostsCalVideoNoShow,
    "AFTER_GUESTS_CAL_VIDEO_NO_SHOW" => Entities.WebhookAfterGuestsCalVideoNoShow,
    "DELEGATION_CREDENTIAL_ERROR" => Entities.WebhookDelegationCredentialError,
    "DELEGATION_CREDENTIAL_SECRET_ROTATED" => Entities.WebhookDelegationCredentialSecretRotated,
    "DELEGATION_CREDENTIAL_SECRET_ROTATION_FAILED" =>
      Entities.WebhookDelegationCredentialSecretRotationFailed,
    "DELEGATION_CREDENTIAL_ROTATION_REQUIRED" =>
      Entities.WebhookDelegationCredentialRotationRequired,
    "WRONG_ASSIGNMENT_REPORT" => Entities.WebhookWrongAssignmentReport,
    "RECORDING_READY" => Entities.WebhookRecordingReady,
    "RECORDING_TRANSCRIPTION_GENERATED" => Entities.WebhookRecordingTranscriptionGenerated,
    "ROUTING_FORM_FALLBACK_HIT" => Entities.WebhookRoutingFormFallbackHit,
    "CALENDAR_ENTRY_REJECTED" => Entities.WebhookCalendarEntryRejected
  }
  @typedoc "The complete source event payload union."
  @type t ::
          Entities.WebhookBookingCreated.t()
          | Entities.WebhookBookingCancelled.t()
          | Entities.WebhookBookingRescheduled.t()
          | Entities.WebhookBookingRequested.t()
          | Entities.WebhookBookingRejected.t()
          | Entities.WebhookBookingPaid.t()
          | Entities.WebhookBookingPaymentInitiated.t()
          | Entities.WebhookBookingNoShowUpdated.t()
          | Entities.WebhookBookingLocationUpdated.t()
          | Entities.WebhookBookingReassigned.t()
          | Entities.WebhookMeetingStarted.t()
          | Entities.WebhookMeetingEnded.t()
          | Entities.WebhookInstantMeeting.t()
          | Entities.WebhookInstantMeetingAccepted.t()
          | Entities.WebhookOooCreated.t()
          | Entities.WebhookFormSubmitted.t()
          | Entities.WebhookFormSubmittedNoEvent.t()
          | Entities.WebhookAfterHostsCalVideoNoShow.t()
          | Entities.WebhookAfterGuestsCalVideoNoShow.t()
          | Entities.WebhookDelegationCredentialError.t()
          | Entities.WebhookDelegationCredentialSecretRotated.t()
          | Entities.WebhookDelegationCredentialSecretRotationFailed.t()
          | Entities.WebhookDelegationCredentialRotationRequired.t()
          | Entities.WebhookWrongAssignmentReport.t()
          | Entities.WebhookRecordingReady.t()
          | Entities.WebhookRecordingTranscriptionGenerated.t()
          | Entities.WebhookRoutingFormFallbackHit.t()
          | Entities.WebhookCalendarEntryRejected.t()
  @doc "Return the exact source trigger names."
  @spec events() :: [String.t()]
  def events, do: Map.keys(@modules)
  @doc "Parse one provider event without hiding documented fields."
  @spec parse(term()) :: {:ok, t()} | {:error, Error.t()}
  def parse(%{"triggerEvent" => event} = raw) do
    case Map.get(@modules, event) do
      nil -> Codec.invalid("webhook triggerEvent")
      module -> module.parse(raw)
    end
  end

  def parse(_raw), do: Codec.invalid("webhook")
end
