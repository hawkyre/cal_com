alias CalCom.Operations

defmodule Operations.AllowlistsControllerGetAllowlist do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_08.json", __MODULE__}
end

defmodule Operations.ApiKeysControllerRefresh do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_08.json", __MODULE__}
end

defmodule Operations.BookingsController20260501GetBookings do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_08.json", __MODULE__}
end

defmodule Operations.BookingsController20260225GetBookingBySeatUid do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_08.json", __MODULE__}
end

defmodule Operations.BookingsController20260225GetBooking do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_08.json", __MODULE__}
end
