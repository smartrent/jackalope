defmodule HareTest do
  use ExUnit.Case
  doctest Hare

  test "greets the world" do
    assert Hare.hello() == :world
  end
end
