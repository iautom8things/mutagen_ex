defmodule ChangedRunFixture.Example do
  @moduledoc false

  def guard_live(x) when x > 10 do
    x * 2
  end

  def guard_live(x), do: x

  def guard_cold(x) when x > 10 do
    x * 3
  end

  def guard_cold(x), do: x

  def multi_live(xs) do
    Enum.reduce(
      xs,
      0,
      fn x, acc -> acc + x end
    )
  end

  def multi_cold(xs) do
    Enum.reduce(
      xs,
      1,
      fn x, acc -> acc * x end
    )
  end

  def pipe(xs, flag) do
    if flag do
      xs
      |> Enum.map(&(&1 + 1))
      |> Enum.filter(&(&1 > 0))
      |> Enum.sum()
    else
      xs
      |> Enum.sort()
      |> Enum.reverse()
      |> Enum.take(1)
    end
  end

  def tup(:a, x) do
    y = x + 1
    {:ok, y}
  end

  def tup(:b, x) do
    y = x - 1
    {:error, y}
  end

  def one_live(x), do: x + 1

  def one_cold(x), do: x - 1

  def two(0), do: :zero

  def two(n) when n > 0 do
    n - 1
  end

  def partial(x) do
    if x > 0 do
      x + 1
    else
      x - 1
    end
  end

  def arm(x) do
    case x do
      :a ->
        1

      :b ->
        0
    end
  end

  def branch_tuple(x, flag) do
    if flag do
      y = abs(x)
      {:ok, y}
    else
      {:error, x}
    end
  end

  def branch_tuple_lit(flag) do
    if flag do
      _ = System.unique_integer()
      {:ok, true}
    else
      {:error, false}
    end
  end

  def branch_tuple_multi(x, flag) do
    if flag do
      y = abs(x)
      {:ok, y}
    else
      {:error, x}
    end
  end

  def cold_tail(x) do
    y = x + 0
    {:ok, y}
  end

  def arm_tuple(x) do
    case x do
      :a -> {:ok, 1}
      :b -> {:error, 0}
    end
  end

  def cond_tuple(x) do
    cond do
      x > 0 -> {:ok, x}
      true -> {:error, 0}
    end
  end

  def with_else(x) do
    with {:ok, y} <- x do
      y
    else
      _ -> {:error, false}
    end
  end

  def with_else_taken(x) do
    with {:ok, y} <- x do
      y
    else
      _ ->
        _ = System.unique_integer()
        {:error, false}
    end
  end

  def nested_branch(x, outer?, inner?) do
    if outer? do
      y = abs(x)

      if inner? do
        {:ok, y}
      else
        {:error, {false, 0}}
      end
    end
  end

  def unless_pipe(xs, flag) do
    unless flag do
      xs
      |> Enum.sort()
      |> Enum.reverse()
      |> Enum.take(1)
    end
  end

  def head_list_live do
    [
      true,
      0
    ]
  end

  def head_list_cold do
    [
      false,
      1
    ]
  end

  def head_map_live,
    do: %{
      enabled: true,
      count: 0
    }

  def head_map_cold,
    do: %{
      enabled: false,
      count: 1
    }

  def head_tuple_live(value) do
    {:ok, value}
  end

  def head_tuple_cold(value) do
    {:ok, value}
  end

  def head_pipe_live(items),
    do:
      items
      |> Enum.sort()
      |> Enum.reverse()

  def head_pipe_cold(items),
    do:
      items
      |> Enum.sort()
      |> Enum.reverse()
end
