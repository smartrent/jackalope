defmodule Jackalope.Persistent.Recovery do
  alias Jackalope.Persistent.ItemFile
  alias Jackalope.Persistent.Meta
  alias Jackalope.PersistentWorkList

  require Logger

  @spec recover(PersistentWorkList.t()) :: PersistentWorkList.t()
  def recover(%PersistentWorkList{} = state) do
    state = restore_metadata(state)

    :ok = File.mkdir_p!(state.data_dir)

    item_files =
      File.ls!(state.data_dir)
      |> Enum.filter(&Regex.match?(~r/.*\.item/, &1))

    now = state.persisted_timestamp

    recovery_state =
      Enum.reduce(
        item_files,
        %{items: [], count: 0, highest_id: 0},
        fn item_file, acc ->
          index = index_of_item_file(item_file)

          with {:ok, item} <- ItemFile.load(state, index),
               true <- acc.count < state.max_size,
               true <- item.expiration > now do
            %{
              acc
              | items: [item | acc.items],
                count: acc.count + 1,
                highest_id: max(item.id, acc.highest_id)
            }
          else
            _ ->
              Logger.warn("Not recovering item in #{inspect(item_file)}. Removing it.")

              ItemFile.delete(state, index)
              acc
          end
        end
      )

    if recovery_state.count == 0 do
      PersistentWorkList.reset_state(state)
    else
      %{
        state
        | next_index: recovery_state.highest_id + 1,
          items_to_send: recovery_state.items,
          count: recovery_state.count
      }
    end
  end

  defp index_of_item_file(item_file) do
    [index_s, _] = String.split(item_file, ".")
    {index, _} = Integer.parse(index_s)
    index
  end

  defp restore_metadata(state) do
    case Meta.load(state) do
      {:ok, meta} ->
        %{state | persisted_timestamp: meta.latest_timestamp}

      _ ->
        # Initialize defaults
        %{state | persisted_timestamp: 0}
    end
  end
end
