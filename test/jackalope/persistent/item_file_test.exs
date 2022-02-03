defmodule Jackalope.Persistent.ItemFileTest do
  use ExUnit.Case, async: true

  alias Jackalope.{Item, Timestamp}
  alias Jackalope.Persistent.ItemFile
  alias Jackalope.PersistentWorkList

  @moduletag :tmp_dir
  doctest ItemFile

  test "saving and loading", context do
    work_list = PersistentWorkList.new(max_size: 10, data_dir: context.tmp_dir)
    now = Timestamp.now(0)
    id = 1

    item = %Item{
      id: id,
      topic: "foo",
      payload: "{\"msg\": \"hello #{id}\"}",
      expiration: Timestamp.ttl_to_expiration(now, 1_000),
      options: [qos: 1]
    }

    assert :ok = ItemFile.save(work_list, item)
    assert File.exists?(Path.join(work_list.data_dir, "#{id}.item"))

    {:ok, loaded_item} = ItemFile.load(work_list, id)
    assert Map.equal?(item, loaded_item)
  end

  test "detecting invalid item on load", context do
    work_list = PersistentWorkList.new(max_size: 10, data_dir: context.tmp_dir)
    now = Timestamp.now(0)

    id = 1

    item = %Item{
      id: id,
      topic: %{},
      payload: "{\"msg\": \"hello #{id}\"}",
      expiration: Timestamp.ttl_to_expiration(now, 1_000),
      options: [qos: 1]
    }

    assert :ok = ItemFile.save(work_list, item)
    :error = ItemFile.load(work_list, id)

    id = 2

    item = %Item{
      id: id,
      topic: "foo",
      payload: %{msg: "hello #{id}"},
      expiration: Timestamp.ttl_to_expiration(now, 1_000),
      options: [qos: 1]
    }

    assert :ok = ItemFile.save(work_list, item)
    :error = ItemFile.load(work_list, id)

    id = 3

    item = %Item{
      id: id,
      topic: "foo",
      payload: "{\"msg\": \"hello #{id}\"}",
      expiration: :infinity,
      options: [qos: 1]
    }

    assert :ok = ItemFile.save(work_list, item)
    :error = ItemFile.load(work_list, id)

    id = 4

    item = %Item{
      id: id,
      topic: "foo",
      payload: "{\"msg\": \"hello #{id}\"}",
      expiration: Timestamp.ttl_to_expiration(now, 1_000),
      options: %{qos: 1}
    }

    assert :ok = ItemFile.save(work_list, item)
    :error = ItemFile.load(work_list, id)
  end

  test "missing dir created on save", context do
    work_list = PersistentWorkList.new(max_size: 10, data_dir: context.tmp_dir)
    now = Timestamp.now(0)
    id = 1

    item = %Item{
      id: id,
      topic: "foo",
      payload: "{\"msg\": \"hello #{id}\"}",
      expiration: Timestamp.ttl_to_expiration(now, 1_000),
      options: [qos: 1]
    }

    File.rmdir!(work_list.data_dir)
    assert :ok = ItemFile.save(work_list, item)
  end
end
