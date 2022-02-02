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
  @spec save(map(), integer(), Item.t()) :: :ok
  def save(state, index, item) do
    path = item_file_path(index, state)
    binary = item_to_binary(item)
    File.write!(path, binary)
  end

  @doc """
  Load the item at an index
  """
  @spec load(map(), integer()) :: {:ok, Item.t()} | :error
  def load(state, index) do
    path = item_file_path(index, state)

    case File.read(path) do
      {:ok, binary} ->
        item_from_binary(binary)

      {:error, :not_found} ->
        Logger.warn("[Jackalope] File not found #{inspect(path)}}")

        :error
    end
  end

  @doc """
  Delete the item persisted at the specified index

  The deletion is best-effort. Errors are ignored.
  """
  @spec delete(map(), integer()) :: :ok
  def delete(state, index) do
    path = item_file_path(index, state)
    _ = File.rm(path)
    :ok
  end

  @doc """
  Return whether there's anything stored for the specified index
  """
  @spec exists?(map(), integer()) :: boolean()
  def exists?(state, index) do
    path = item_file_path(index, state)
    File.exists?(path)
  end

  defp item_file_path(index, %{data_dir: data_dir}) do
    Path.join(data_dir, "#{index}.item")
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
