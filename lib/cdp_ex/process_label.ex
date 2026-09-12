defmodule CDPEx.ProcessLabel do
  @moduledoc false

  # `Process.set_label/1` arrived in Elixir 1.17 and cdp_ex still supports 1.15,
  # so the call is resolved at compile time and becomes a no-op on older versions
  # rather than paying a `function_exported?/3` check per process.

  if function_exported?(Process, :set_label, 1) do
    @spec set(term()) :: :ok
    def set(label), do: Process.set_label(label)
  else
    @spec set(term()) :: :ok
    def set(_label), do: :ok
  end
end
