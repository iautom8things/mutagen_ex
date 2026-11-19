defmodule Wrd25Bench.CaseDense do
  @moduledoc """
  Case-clause-dense module for the wrd25 bench fixture.

  Multi-clause `case` blocks so `:case_drop` surfaces every clause
  as a candidate site. Bodies also contain arithmetic/boolean ops to
  add cross-mutator density.
  """

  def classify(n) do
    case n do
      0 -> :zero
      1 -> :one
      2 -> :two
      n when n < 0 -> :negative
      n when n < 10 -> :small
      n when n < 100 -> :medium
      _ -> :large
    end
  end

  def shape(t) do
    case t do
      {:ok, v} -> v + 1
      {:error, _} -> 0
      :none -> -1
      :empty -> 0
      [] -> 0
      [_h | _t] -> 1
      n when is_integer(n) -> n * 2
      _ -> -2
    end
  end

  def http_status(code) do
    case code do
      200 -> :ok
      201 -> :created
      204 -> :no_content
      301 -> :moved
      302 -> :found
      400 -> :bad_request
      401 -> :unauthorized
      403 -> :forbidden
      404 -> :not_found
      500 -> :server_error
      _ -> :other
    end
  end

  def severity(level) do
    case level do
      :debug -> 0
      :info -> 1
      :warn -> 2
      :error -> 3
      :fatal -> 4
      _ -> -1
    end
  end

  def quadrant(x, y) do
    case {x > 0, y > 0} do
      {true, true} -> 1
      {false, true} -> 2
      {false, false} -> 3
      {true, false} -> 4
    end
  end
end
