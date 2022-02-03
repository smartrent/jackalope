defmodule Jackalope.Persistent.Meta do
  @moduledoc """
  Functions for saving and restoring persistence metadata
  """

  alias Jackalope.Timestamp

  require Logger

  @meta_version 1
  @meta_file_length 24

  @type metadata() :: %{
          latest_timestamp: Timestamp.t(),
          next_index: non_neg_integer()
        }

  @spec save(map(), Timestamp.t()) :: :ok
  def save(state, now) do
    contents = encode(now, state.next_index)

    write!(state.data_dir, "meta", contents)
  end

  defp write!(data_dir, filename, contents) do
    path = Path.join(data_dir, filename)
    tmp_path = path <> ".tmp"

    write_options = [:sync]

    case File.write(tmp_path, contents, write_options) do
      :ok ->
        File.rename!(tmp_path, path)
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

  @spec load(map()) :: {:ok, metadata()} | :error
  def load(state) do
    path = Path.join(state.data_dir, "meta")

    # Read the file manually rather than by calling File.read! so
    # that no more than the max size is read "just in case"
    with {:ok, file} <- File.open(path, [:binary]),
         contents when is_binary(contents) <- IO.binread(file, @meta_file_length),
         {:ok, meta} <- decode(contents) do
      _ = File.close(file)
      {:ok, meta}
    else
      _ ->
        Logger.warn("[Jackalope] Invalid or missing persistence metadata")
        :error
    end
  end

  defp encode(latest_timestamp, next_index) do
    <<@meta_version::8, 0::56, latest_timestamp::signed-64, next_index::64>>
  end

  defp decode(<<@meta_version::8, 0::56, latest_timestamp::signed-64, next_index::64>>) do
    {:ok, %{latest_timestamp: latest_timestamp, next_index: next_index}}
  end

  defp decode(_other) do
    :error
  end
end
