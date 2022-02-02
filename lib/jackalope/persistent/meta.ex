defmodule Jackalope.Persistent.Meta do
  @moduledoc """
  Functions for saving and restoring persistence metadata
  """

  alias Jackalope.Timestamp

  require Logger

  @type metadata() :: %{latest_timestamp: Timestamp.t()}

  @spec save(map(), Timestamp.t()) :: :ok
  def save(state, now) do
    time = now |> Integer.to_string()
    new_time_path = Path.join(state.data_dir, "new_time")
    time_path = Path.join(state.data_dir, "time")
    File.write!(new_time_path, time, [:write])
    File.rename!(new_time_path, time_path)
  end

  @spec load(map()) :: {:ok, metadata()} | :error
  def load(state) do
    path = Path.join(state.data_dir, "time")

    with {:ok, contents} <- File.read(path),
         {time, _} <- Integer.parse(contents) do
      {:ok, %{latest_timestamp: time}}
    else
      _ ->
        Logger.warn("[Jackalope] Invalid or missing persistence metadata")
        :error
    end
  end
end
