defmodule Jackalope.Session do
  @moduledoc false

  # MQTT session logic

  # The Jackalope module will serve as a message box, tracking the
  # status of the messages currently handled by Tortoise. This part of
  # the application is not supervised in the same supervision branch as
  # Tortoise, so we shouldn't drop important messages if Tortoise, or
  # any of its siblings should crash; and we should retry messages that
  # was not delivered for whatever reason.

  use GenServer

  require Logger

  alias __MODULE__, as: State
  alias Jackalope.TortoiseClient

  @version 1

  defstruct connection_status: :offline,
            handler: nil,
            work_list: [],
            pending: %{},
            subscriptions: %{}

  def start_link(opts) do
    Logger.info("[Jackalope] Starting #{inspect(__MODULE__)}...")
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def whereis() do
    GenServer.whereis(__MODULE__)
  end

  ## MQTT-ing
  @doc false
  def subscribe(subscription, opts \\ [])

  def subscribe({topic_filter, subscribe_opts}, opts) do
    cmd = {:subscribe, topic_filter, subscribe_opts}

    cond do
      Keyword.get(subscribe_opts, :qos, 0) not in [0, 1] ->
        {:error, :unsupported_qos}

      _opts_looks_good! = true ->
        GenServer.cast(__MODULE__, {:cmd, cmd, opts})
    end
  end

  def subscribe(topic_filter, opts) do
    # lift the input to the correct format
    subscribe({topic_filter, []}, opts)
  end

  @doc false
  def unsubscribe(unsubscribe, opts \\ [])

  def unsubscribe({topic_filter, unsubscribe_opts}, opts) do
    cmd = {:unsubscribe, topic_filter, unsubscribe_opts}
    GenServer.cast(__MODULE__, {:cmd, cmd, opts})
  end

  def unsubscribe(topic_filter, opts) do
    # lift the input to the correct format
    unsubscribe({topic_filter, []}, opts)
  end

  @doc false
  def publish(topic_and_opts, payload, opts \\ [])

  def publish({topic_levels, publish_opts}, payload, opts) when is_list(topic_levels) do
    # normalize the topic list, should be a string
    topic = Enum.join(topic_levels, "/")
    publish({topic, publish_opts}, payload, opts)
  end

  def publish(topic, payload, opts) when not is_tuple(topic) do
    # normalize the topic to include the publish opts
    publish({topic, []}, payload, opts)
  end

  def publish({topic, publish_opts}, payload, opts) do
    cmd = {:publish, topic, payload, publish_opts}

    # Ensure the opts passed to the publish are allowed by AWS IoT
    cond do
      Keyword.get(publish_opts, :qos, 0) not in [0, 1] ->
        {:error, :unsupported_qos}

      Keyword.get(publish_opts, :retain, false) == true ->
        {:error, :retain_not_supported}

      _opts_looks_good! = true ->
        GenServer.cast(__MODULE__, {:cmd, cmd, opts})
    end
  end

  @doc false
  def status() do
    GenServer.call(__MODULE__, :status)
  end

  @doc false
  def reconnect() do
    GenServer.cast(__MODULE__, :reconnect)
  end

  @impl true
  def init(opts) do
    handler = Keyword.fetch!(opts, :handler)
    # Produce subscription commands for the initial subscriptions
    initial_topics = Keyword.get(opts, :initial_topics)

    subscriptions =
      for topic_filter <- List.wrap(initial_topics),
          do: {{:subscribe, topic_filter, []}, []}

    {:ok, saved_work_list} = retrieve_worklist()
    work_list = Enum.concat(saved_work_list, subscriptions)

    initial_state = %State{work_list: work_list, handler: handler}

    {:ok, initial_state, {:continue, :consume_work_list}}
  end

  @impl true
  def handle_call(:status, _from, %State{} = state) do
    {:reply, Map.from_struct(state), state}
  end

  @impl true
  # Connection status changes
  def handle_info({:connection_status, :up}, state) do
    state = %State{state | connection_status: :online}
    {:noreply, state, {:continue, :consume_work_list}}
  end

  def handle_info({:connection_status, status}, state)
      when status in [:down, :terminating, :terminated] do
    state = %State{
      state
      | connection_status: :offline,
        # Reset the subscriptions and schedule a resubscribe to all
        # the current subscriptions for when we are back online. Note;
        # MQTT sessions should be able to handle this, but we do it
        # for good measure to ensure a consistent state of the world;
        # an upcoming Tortoise version will track this state in the
        # connection state, and the user can ask for it, so this
        # problem will go away in the future; also, as we add the
        # subscribe work-order at the front of the list, any
        # unsubscribe placed should come after this, making sure we
        # will not resubscribe to a topic we are no longer interested
        # in.
        subscriptions: %{},
        work_list:
          persist_worklist(
            Enum.concat([
              for(
                {topic_filter, opts} <- state.subscriptions,
                do: {{:subscribe, topic_filter, opts}, []}
              ),
              state.work_list
            ])
          )
    }

    {:noreply, state}
  end

  # Handle responses to user initiated commands; subscribe,
  # unsubscribe, publish...
  def handle_info(
        {:tortoise_result, ref, res},
        %State{pending: pending} = state
      ) do
    {work_order, pending} = Map.pop(pending, ref)
    state = %State{state | pending: pending}

    case res do
      _unknown_ref when is_nil(work_order) ->
        Logger.info("Received unknown ref from Tortoise: #{inspect(ref)}")
        {:noreply, state}

      :ok ->
        case work_order do
          {{:subscribe, topic, subscription_opts}, _opts} ->
            # Note that all subscriptions has to go through Jackalope;
            # for that reason we cannot use the "initial
            # subscriptions" in Tortoise, as Jackalope would not know
            # about them; the upcoming Tortoise will expose a function
            # for the subscriptions state!
            state = %State{
              state
              | subscriptions: Map.put(state.subscriptions, topic, subscription_opts)
            }

            {:noreply, state}

          {{:unsubscribe, topic, _}, _opts} ->
            state = %State{
              state
              | subscriptions: Map.delete(state.subscriptions, topic)
            }

            {:noreply, state}

          _otherwise ->
            {:noreply, state}
        end

      {:error, reason} ->
        Logger.warn("Retrying message, failed with reason: #{inspect(reason)}")
        state = %State{state | work_list: persist_worklist([work_order | state.work_list])}
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:cmd, cmd, opts}, %State{work_list: work_list} = state) do
    # Setup the options for the work order; so far we support time to
    # live, which allow us to specify the time a work order is allowed
    # to stay in the work list before it is deemed irrelevant
    opts =
      Keyword.update(opts, :ttl, :infinity, fn
        :infinity -> :infinity
        ttl when is_integer(ttl) -> System.monotonic_time(:millisecond) + ttl
      end)

    # Note that we don't really concern ourselves with the order of
    # the commands; the work_list is a list (and thus a stack) and when
    # we retry a message it will reenter the work list at the front,
    # and it could already have messages, etc.
    work_list = [{cmd, opts} | work_list]
    state = %State{state | work_list: persist_worklist(work_list)}
    {:noreply, state, {:continue, :consume_work_list}}
  end

  def handle_cast(:reconnect, state) do
    :ok = Jackalope.TortoiseClient.reconnect()

    state = %State{
      state
      | connection_status: :offline,
        # We will republish all the messages we got in pending; this
        # might result in messages being received twice, but this is
        # already an issue with QoS=1 messages; subscribes and
        # unsubscribes should be idempotent
        pending: %{},
        work_list:
          persist_worklist(
            Enum.concat([
              for(
                {ref, work_order} when is_reference(ref) <- state.pending,
                do: work_order
              ),
              state.work_list
            ])
          )
    }

    {:noreply, state}
  end

  @impl true
  def handle_continue(:consume_work_list, %State{connection_status: :offline} = state) do
    # postpone consuming from the work list till we are online again!
    {:noreply, state}
  end

  def handle_continue(:consume_work_list, %State{work_list: []} = state) do
    # base-case; we are done consuming and will idle until more work
    # is produced
    {:noreply, state}
  end

  # reductive case, consume work until the work list is empty
  def handle_continue(
        :consume_work_list,
        %State{
          connection_status: :online,
          work_list: [{cmd, opts} = work_order | remaining],
          pending: pending
        } = state
      ) do
    state = %State{state | work_list: remaining}
    ttl = Keyword.get(opts, :ttl, :infinity)

    if ttl > System.monotonic_time(:millisecond) do
      case execute_work(cmd) do
        :ok ->
          # fire and forget work; Publish with QoS=0 is among the work
          # that doesn't produce references
          persist_worklist(state.work_list)
          {:noreply, state, {:continue, :consume_work_list}}

        {:ok, ref} ->
          state = %State{state | pending: Map.put_new(pending, ref, work_order)}
          persist_worklist(state.work_list)
          {:noreply, state, {:continue, :consume_work_list}}

        {:error, :no_connection} ->
          {:noreply, %{state | work_list: persist_worklist([work_order | remaining])}}
      end
    else
      # drop the message, it is outside of the time to live
      if function_exported?(state.handler, :handle_error, 1) do
        reason = {:publish_error, cmd, :ttl_expired}
        apply(state.handler, :handle_error, [reason])
      end

      {:noreply, state, {:continue, :consume_work_list}}
    end
  end

  ### PERSIST HELPERS --------------------------------------------------
  def persist_worklist(value) do
    filename = Path.join(data_dir(), Integer.to_string(:os.system_time()) <> "_worklist")
    work_list = :erlang.term_to_binary(value)
    md5 = :erlang.md5(work_list)

    data = <<
      @version::size(8),
      md5::binary-size(16),
      work_list::binary
    >>

    _ =
      case File.write(filename, data, [:sync]) do
        :ok ->
          cleanup_stored_worklists()

        {:error, reason} ->
          Logger.warn(
            "Jackalope] Failed to persist worklist #{inspect(value)}: #{inspect(reason)}"
          )
      end

    value
  end

  def retrieve_worklist() do
    {:ok, files} = data_dir() |> File.ls()

    if files == [] do
      {:ok, []}
    else
      worklist =
        files
        |> Enum.sort(:desc)
        |> Enum.find_value(fn filename ->
          case File.read(Path.join(data_dir(), filename)) do
            {:ok, data} ->
              maybe_data_to_term(data)

            {:error, reason} ->
              Logger.warn(
                "[Jackalope] Failed to read worklist file #{filename}: #{inspect(reason)}"
              )

              nil
          end
        end)

      {:ok, worklist || []}
    end
  end

  def cleanup_stored_worklists() do
    {:ok, files} = data_dir() |> File.ls()

    case Enum.sort(files, :desc) do
      [] ->
        :ok

      [_ | old_files] ->
        old_files |> Enum.each(fn filename -> File.rm!(Path.join(data_dir(), filename)) end)
    end
  end

  def remove_all_worklists() do
    {:ok, files} = data_dir() |> File.ls()
    Enum.each(files, fn filename -> File.rm(Path.join(data_dir(), filename)) end)
  end

  defp data_dir() do
    dir = Application.get_env(:jackalope, :data_dir)
    :ok = File.mkdir_p!(dir)
    dir
  end

  def checked_bin_to_term(<<@version::size(8), md5::binary-size(16), bin::binary>>) do
    computed_md5 = :erlang.md5(bin)

    if computed_md5 == md5 do
      {:ok, :erlang.binary_to_term(bin)}
    else
      {:error, :invalid_hash}
    end
  end

  def checked_bin_to_term(<<@version::size(8), _other_stuff::binary>>),
    do: {:error, :truncated_data}

  def checked_bin_to_term(""),
    do: {:error, :empty}

  def checked_bin_to_term(_other), do: raise("Unsupported_version")

  ### PRIVATE HELPERS --------------------------------------------------

  defp maybe_data_to_term(data) do
    case checked_bin_to_term(data) do
      {:error, reason} ->
        Logger.warn("[Jackalope] Failed to extract worklist from data: #{inspect(reason)}")

        nil

      {:ok, term} ->
        term
    end
  end

  defp execute_work({:publish, topic, payload, opts}) do
    TortoiseClient.publish(topic, payload, opts)
  end

  defp execute_work({:subscribe, topic_filter, opts}) do
    TortoiseClient.subscribe(topic_filter, opts)
  end

  defp execute_work({:unsubscribe, topic_filter, opts}) do
    # the unsubscribe does not take any options, but it might do in
    # the future, keeping it to make future upgrades easier
    TortoiseClient.unsubscribe(topic_filter, opts)
  end
end
