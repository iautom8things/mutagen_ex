defmodule Wrd25Bench.CaseDenseTest do
  use ExUnit.Case, async: false
  alias Wrd25Bench.CaseDense

  test "classify covers each clause" do
    assert CaseDense.classify(0) == :zero
    assert CaseDense.classify(1) == :one
    assert CaseDense.classify(2) == :two
    assert CaseDense.classify(-3) == :negative
    assert CaseDense.classify(5) == :small
    assert CaseDense.classify(50) == :medium
    assert CaseDense.classify(500) == :large
  end

  test "shape covers each clause" do
    assert CaseDense.shape({:ok, 1}) == 2
    assert CaseDense.shape({:error, :reason}) == 0
    assert CaseDense.shape(:none) == -1
    assert CaseDense.shape(:empty) == 0
    assert CaseDense.shape([]) == 0
    assert CaseDense.shape([1, 2]) == 1
    assert CaseDense.shape(7) == 14
    assert CaseDense.shape(:something_else) == -2
  end

  test "http_status covers each branch" do
    assert CaseDense.http_status(200) == :ok
    assert CaseDense.http_status(201) == :created
    assert CaseDense.http_status(204) == :no_content
    assert CaseDense.http_status(301) == :moved
    assert CaseDense.http_status(302) == :found
    assert CaseDense.http_status(400) == :bad_request
    assert CaseDense.http_status(401) == :unauthorized
    assert CaseDense.http_status(403) == :forbidden
    assert CaseDense.http_status(404) == :not_found
    assert CaseDense.http_status(500) == :server_error
    assert CaseDense.http_status(999) == :other
  end

  test "severity levels" do
    assert CaseDense.severity(:debug) == 0
    assert CaseDense.severity(:info) == 1
    assert CaseDense.severity(:warn) == 2
    assert CaseDense.severity(:error) == 3
    assert CaseDense.severity(:fatal) == 4
    assert CaseDense.severity(:other) == -1
  end

  test "quadrant" do
    assert CaseDense.quadrant(1, 1) == 1
    assert CaseDense.quadrant(-1, 1) == 2
    assert CaseDense.quadrant(-1, -1) == 3
    assert CaseDense.quadrant(1, -1) == 4
  end
end
