alias CalCom.Operations

defmodule Operations.BookingAttendeesController20240813AddAttendee do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_27.json", __MODULE__}
end

defmodule Operations.BookingGuestsController20240813AddGuests do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_27.json", __MODULE__}
end

defmodule Operations.SlotsController20240904ReserveSlot do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_27.json", __MODULE__}
end

defmodule Operations.SlotsController20240904UpdateReservedSlot do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_27.json", __MODULE__}
end

defmodule Operations.SlotsController20240904DeleteReservedSlot do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_27.json", __MODULE__}
end
