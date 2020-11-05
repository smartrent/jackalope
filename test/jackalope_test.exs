defmodule JackalopeTest do
  use ExUnit.Case
  doctest Jackalope

  test "greets the world" do
    assert Jackalope.hello() == :world
  end
end
