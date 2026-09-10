# Delete anything a certification run left behind, by name.
#
#   CAL_COM_API_KEY=... mix run scripts/reap.exs          # report and delete
#   CAL_COM_API_KEY=... mix run scripts/reap.exs --dry    # report only
#
# The sweeps call this themselves; it is runnable on its own to check an account
# after an interrupted run. It only ever deletes rows carrying the certification
# marker, and cancels bookings rather than deleting them.
Code.require_file("sweep/reap.exs", __DIR__)

apply? = "--dry" not in System.argv()
count = Sweep.Reap.reap(apply?)

IO.puts("\n#{count} fixtures #{if apply?, do: "reaped", else: "found"}")
