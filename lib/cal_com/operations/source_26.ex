alias CalCom.Operations

defmodule Operations.BookingsController20260225DeclineBooking do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_26.json", __MODULE__}
end

defmodule Operations.BookingsController20260225RequestReschedule do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_26.json", __MODULE__}
end

defmodule Operations.BookingLocationController20240813UpdateBookingLocation do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_26.json", __MODULE__}
end

defmodule Operations.BookingsVerificationControllerSendEmailVerificationCode do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_26.json", __MODULE__}
end

defmodule Operations.BookingsVerificationControllerVerifyEmailCode do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_26.json", __MODULE__}
end
