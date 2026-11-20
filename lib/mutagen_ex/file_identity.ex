defmodule MutagenEx.FileIdentity do
  @moduledoc false

  def key(%File.Stat{} = stat), do: {stat.major_device, stat.minor_device, stat.inode}

  def same?(left, right) do
    with {:ok, a} <- File.stat(left),
         {:ok, b} <- File.stat(right) do
      key(a) == key(b)
    else
      _ -> false
    end
  end
end
