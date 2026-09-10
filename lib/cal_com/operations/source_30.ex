alias CalCom.Operations

defmodule Operations.BookingGuestsController20240813AddGuests do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_30.json", __MODULE__}
end

defmodule Operations.BookingRoutingTraceController20240813GetBookingRoutingTrace do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_30.json", __MODULE__}
end

defmodule Operations.CalUnifiedCalendarsControllerGetCalendarEventDetails do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_30.json", __MODULE__}
end

defmodule Operations.CalUnifiedCalendarsControllerUpdateCalendarEvent do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_30.json", __MODULE__}
end

defmodule Operations.CalendarsControllerCreateIcsFeed do
  @moduledoc "A complete typed Cal provider operation."
  use CalCom.OperationModule, source: {"operation_contracts_30.json", __MODULE__}
end
