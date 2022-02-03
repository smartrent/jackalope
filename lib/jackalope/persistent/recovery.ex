defmodule Jackalope.Persistent.Recovery do
  # def recover(state) do
  #   state = restore_metadata(state)

  #   :ok = File.mkdir_p!(state.data_dir)

  #   item_files =
  #     File.ls!(state.data_dir)
  #     |> Enum.filter(&Regex.match?(~r/.*\.item/, &1))

  #   expirations =
  #     item_files
  #     |> Enum.reduce(
  #       [],
  #       fn item_file, acc ->
  #         index = index_of_item_file(item_file)

  #         case ItemFile.load(state, index) do
  #           {:ok, item} ->
  #             [{index, item.expiration} | acc]

  #           :error ->
  #             Logger.warn("Failed to recover item in #{inspect(item_file)}. Removing it.")

  #             ItemFile.delete(state, index)
  #             acc
  #         end
  #       end
  #     )
  #     |> Enum.into(%{})

  #   item_indices = Map.keys(expirations)

  #   if Enum.empty?(item_files) do
  #     reset_state(state)
  #   else
  #     bottom_index = Enum.min(item_indices)
  #     last_index = Enum.max(item_indices)

  #     %State{
  #       state
  #       | bottom_index: bottom_index,
  #         next_index: last_index + 1,
  #         expirations: expirations
  #     }
  #   end
  # end
end
