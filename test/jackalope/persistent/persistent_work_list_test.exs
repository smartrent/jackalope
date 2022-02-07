defmodule Jackalope.Persistent.PersistentWorkListTest do
  use ExUnit.Case, async: false

  alias Jackalope.{Item, Timestamp, WorkList}
  alias Jackalope.PersistentWorkList

  @one_day 86_400_000

  @moduletag :tmp_dir
  doctest PersistentWorkList

  test "Create work list", context do
    pwl = new_pwl(context)
    assert pwl.max_size == 10
    assert pwl.count == 0
    assert pwl.next_index == 0
    assert Enum.empty?(pwl.items_to_send())
    assert Enum.empty?(pwl.items_in_transit())
    assert pwl.data_dir == context.tmp_dir
    assert :ok = PersistentWorkList.check_consistency(pwl)
  end

  test "Push one item", context do
    pwl = new_pwl(context)
    now = Timestamp.now(0)

    i = pwl.next_index
    pwl = WorkList.push(pwl, make_item(i, @one_day), now)

    assert pwl.count == 1
    assert pwl.next_index == 1
    assert Enum.count(pwl.items_to_send()) == 1
    assert Enum.empty?(pwl.items_in_transit())
    assert :ok = PersistentWorkList.check_consistency(pwl)
  end

  test "Push many items", context do
    pwl = new_pwl(context)

    pwl =
      for i <- pwl.next_index..4, reduce: pwl do
        acc -> WorkList.push(acc, make_item(i, @one_day), Timestamp.now(0))
      end

    assert pwl.count == 5
    assert pwl.next_index == 5
    assert Enum.count(pwl.items_to_send()) == 5
    assert Enum.empty?(pwl.items_in_transit())
    assert :ok = PersistentWorkList.check_consistency(pwl)
  end

  test "Sync latest known state", context do
    pwl = new_pwl(context)

    pwl =
      for i <- pwl.next_index..5, reduce: pwl do
        acc -> WorkList.push(acc, make_item(i, @one_day), Timestamp.now(0))
      end

    meta = WorkList.latest_known_state(pwl)
    assert meta.id == 6
    assert 0 == meta.timestamp

    now = Timestamp.now(0)
    pwl = WorkList.sync(pwl, now)
    meta = WorkList.latest_known_state(pwl)
    assert meta.id == 6
    assert now == meta.timestamp
    assert :ok = PersistentWorkList.check_consistency(pwl)
  end

  test "Pop", context do
    pwl = new_pwl(context)

    pwl =
      for i <- pwl.next_index..5, reduce: pwl do
        acc -> WorkList.push(acc, make_item(i, @one_day), Timestamp.now(0))
      end

    now = Timestamp.now(0)

    pwl =
      for i <- 1..2, reduce: pwl do
        acc -> WorkList.pop(acc)
      end

    pwl = WorkList.sync(pwl, now)
    meta = WorkList.latest_known_state(pwl)
    assert meta.id == 6
    assert pwl.count == 4
    assert pwl.next_index == 6
    assert Enum.count(pwl.items_to_send()) == 4
    assert Enum.empty?(pwl.items_in_transit())
    assert :ok = PersistentWorkList.check_consistency(pwl)
  end

  test "Peek", context do
    pwl = new_pwl(context)

    pwl =
      for i <- pwl.next_index..5, reduce: pwl do
        acc -> WorkList.push(acc, make_item(i, @one_day), Timestamp.now(0))
      end

    peek = WorkList.peek(pwl)
    assert peek.id == 5
    pwl = WorkList.pop(pwl)
    peek = WorkList.peek(pwl)
    assert peek.id == 4
    assert :ok = PersistentWorkList.check_consistency(pwl)
  end

  test "Pending", context do
    pwl = new_pwl(context)

    pwl =
      for i <- pwl.next_index..5, reduce: pwl do
        acc -> WorkList.push(acc, make_item(i, @one_day), Timestamp.now(0))
      end

    assert pwl.count == 6

    ref = make_ref()
    assert Map.get(pwl.items_in_transit(), ref) == nil
    pwl = WorkList.pending(pwl, ref, Timestamp.now(0))
    assert pwl.next_index == 6
    assert pwl.count == 6
    assert Enum.count(pwl.items_to_send()) == 5
    assert Enum.count(pwl.items_in_transit()) == 1
    pending_item = Map.get(pwl.items_in_transit(), ref)
    assert pending_item.id == 5
    assert :ok = PersistentWorkList.check_consistency(pwl)
  end

  test "Done", context do
    pwl = new_pwl(context)

    pwl =
      for i <- pwl.next_index..5, reduce: pwl do
        acc -> WorkList.push(acc, make_item(i, @one_day), Timestamp.now(0))
      end

    assert pwl.count == 6

    ref = make_ref()
    pwl = WorkList.pending(pwl, ref, Timestamp.now(0))
    {pwl, done_item} = WorkList.done(pwl, ref)
    done_item.id == 5
    assert pwl.count == 5
    {pwl, done_item} = WorkList.done(pwl, ref)
    assert done_item == nil
    assert pwl.count == 5
    assert :ok = PersistentWorkList.check_consistency(pwl)
  end

  defp new_pwl(context) do
    File.rm_rf!(context.tmp_dir)
    PersistentWorkList.new(max_size: 10, data_dir: context.tmp_dir)
  end

  defp make_item(i, ttl) do
    %Item{
      id: i,
      topic: "foo",
      payload: "{\"msg\": \"hello #{i}\"}",
      expiration: Timestamp.ttl_to_expiration(Timestamp.now(0), ttl),
      options: [qos: 1]
    }
  end
end
