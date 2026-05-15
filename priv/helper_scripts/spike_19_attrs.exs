# Confirms the persisted-attribute observation independent of :cover.
#
# Run with: mix run priv/helper_scripts/spike_19_attrs.exs

defmodule SpikeSchema do
  defmacro __using__(_) do
    quote do
      Module.register_attribute(__MODULE__, :foo, persist: true)
      @foo :bar
    end
  end
end

defmodule SpikeUser do
  use SpikeSchema
end

attrs = SpikeUser.__info__(:attributes)
IO.puts("attrs = #{inspect(attrs)}")
IO.puts("Keyword.get_values(attrs, :foo) = #{inspect(Keyword.get_values(attrs, :foo))}")
IO.puts(":bar in Keyword.get_values? = #{inspect(:bar in Keyword.get_values(attrs, :foo))}")
IO.puts(":bar in List.flatten(...)?  = #{inspect(:bar in List.flatten(Keyword.get_values(attrs, :foo)))}")
