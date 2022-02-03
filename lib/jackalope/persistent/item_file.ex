defmodule Jackalope.Persistent.ItemFile do
  @moduledoc """
  Functions for persisting Jackalope.Item structs
  """
  alias Jackalope.Item

  require Logger

  @doc """
  Save an item

  The item is persisted at the specified index.
  """
  @spec save(map(), Item.t()) :: :ok
  def save(state, item) do
    contents = item_to_binary(item)
    write!(state.data_dir, item_filename(item.id), contents)
  end

  defp write!(data_dir, filename, contents) do
    path = Path.join(data_dir, filename)
    write_options = [:sync]

    case File.write(path, contents, write_options) do
      :ok ->
        :ok

      _error ->
        # Try to recover
        #   1. Maybe the parent directory doesn't exist
        #   2. Maybe there's a file in the way
        File.mkdir_p!(data_dir)
        _ = File.rm(path)
        File.write!(path, contents, write_options)
    end
  end

  @doc """
  Load the item at an index
  """
  @spec load(map(), non_neg_integer()) :: {:ok, Item.t()} | :error
  def load(state, id) do
    path = Path.join(state.data_dir, item_filename(id))

    with {:ok, binary} <- File.read(path),
         {:ok, item} <- item_from_binary(binary),
         true <- good_item?(item, id) do
      {:ok, item}
    else
      _ ->
        Logger.warn("[Jackalope] File #{inspect(path)}} not found or corrupt.")
        :error
    end
  end

  defp good_item?(
         %Item{id: id, expiration: expiration, topic: topic, payload: payload, options: options} =
           _item,
         id
       )
       when is_integer(expiration) and is_binary(topic) and is_binary(payload) and
              is_list(options) do
    true
  end

  defp good_item?(_item, _id), do: false

  @doc """
  Delete the item persisted at the specified index

  The deletion is best-effort. Errors are ignored.
  """
  @spec delete(map(), non_neg_integer()) :: :ok
  def delete(state, id) when id >= 0 do
    path = Path.join(state.data_dir, item_filename(id))
    _ = File.rm(path)
    :ok
  end

  @doc """
  Return whether there's anything stored for the specified index
  """
  @spec exists?(map(), non_neg_integer()) :: boolean()
  def exists?(state, id) when id >= 0 do
    path = Path.join(state.data_dir, item_filename(id))
    File.exists?(path)
  end

  def exists?(_state, _id) do
    false
  end

  defp item_filename(id) when is_integer(id) and id >= 0 do
    "#{id}.item"
  end

  defp item_from_binary(binary) do
    item = :erlang.binary_to_term(binary)
    {:ok, item}
  rescue
    error ->
      Logger.warn("[Jackalope] Failed to convert work item from binary: #{inspect(error)}")
      {:error, :invalid}
  end

  defp item_to_binary(item), do: :erlang.term_to_binary(item)
end
