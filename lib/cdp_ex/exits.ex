defmodule CDPEx.Exits do
  @moduledoc false
  # Shared by the stop/close helpers that turn an exit from an already-gone process
  # into :ok.

  require Logger

  # A reason other than "already gone" (or Chrome dying underneath the stop) means
  # terminate/2 itself failed, which can leave Chrome unreaped; the stop helpers still
  # return :ok but say so.
  @spec warn_unclean_stop(String.t(), term()) :: :ok
  def warn_unclean_stop(_who, reason)
      when reason in [:noproc, :normal, :shutdown] or
             (is_tuple(reason) and elem(reason, 0) in [:shutdown, :chrome_exited]) do
    :ok
  end

  def warn_unclean_stop(who, reason) do
    Logger.warning("[#{who}] stopped with #{inspect(reason)} rather than cleanly")
    :ok
  end
end
