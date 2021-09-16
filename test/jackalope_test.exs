defmodule JackalopeTest do
  use ExUnit.Case, async: false
  doctest Jackalope

  alias Jackalope.WorkList
  alias Jackalope.WorkList.Expiration
  alias JackalopeTest.ScriptedMqttServer, as: MqttServer
  alias Tortoise311.Package

  @work_list_mod Jackalope.PersistentWorkList

  setup context do
    {:ok, mqtt_server_pid} = start_supervised(MqttServer)
    Process.link(mqtt_server_pid)
    client_id = Atom.to_string(context.test)
    {:ok, [client_id: client_id, mqtt_server_pid: mqtt_server_pid]}
  end

  describe "start_link/1" do
    test "connect to a MQTT server (tcp)", context do
      transport = setup_server(context)

      assert {:ok, pid} =
               Jackalope.start_link(
                 server: transport,
                 client_id: context.client_id,
                 handler: JackalopeTest.TestHandler,
                 work_list_mod: @work_list_mod,
                 data_dir: "/tmp"
               )

      assert_receive {MqttServer, {:received, %Package.Connect{}}}

      assert is_pid(pid)
      assert Process.alive?(pid)

      assert_receive {MqttServer, :completed}, 200
    end
  end

  describe "publish/3" do
    test "publish with QoS=0", context do
      connect(context)

      flush =
        expect_publish(
          context,
          qos: 0,
          topic: "foo",
          payload: expected_payload = %{"msg" => "hello"}
        )

      assert :ok = Jackalope.publish("foo", %{"msg" => "hello"}, qos: 0)
      # this is what the server received
      assert %Package.Publish{topic: "foo", qos: 0, payload: payload} = flush.()
      assert expected_payload == Jason.decode!(payload)
    end

    test "publish with QoS=1", context do
      connect(context)

      flush =
        expect_publish(
          context,
          qos: 1,
          topic: "foo",
          payload: expected_payload = %{"msg" => "hello"}
        )

      assert :ok = Jackalope.publish("foo", %{"msg" => "hello"}, qos: 1)
      # this is what the server received
      assert received_publish = flush.()
      assert %Package.Publish{topic: "foo", qos: 1} = received_publish
      assert expected_payload == Jason.decode!(received_publish.payload)
    end
  end

  defp get_session_work_list() do
    :sys.get_state(Jackalope.Session).work_list
  end

  describe "work list" do
    test "dropping work orders", context do
      connect(context, max_work_list_size: 10)
      pause_mqtt_server(context)

      work_list = get_session_work_list()

      work_list =
        Enum.reduce(1..15, work_list, fn i, acc ->
          WorkList.push(
            acc,
            {{:publish, "foo", %{"msg" => "hello #{i}"}, [qos: 1]},
             [expiration: Expiration.expiration(:infinity)]}
          )
        end)

      assert WorkList.count(work_list) == 10
    end

    test "pending and done work items", context do
      connect(context, max_work_list_size: 10)
      pause_mqtt_server(context)

      work_list = get_session_work_list()

      work_list =
        Enum.reduce(1..5, work_list, fn i, acc ->
          WorkList.push(
            acc,
            {{:publish, "foo", %{"msg" => "hello #{i}"}, [qos: 1]},
             [expiration: Expiration.expiration(:infinity)]}
          )
        end)

      assert WorkList.count(work_list) == 5

      ref = make_ref()

      {work_list, _item} =
        work_list
        |> WorkList.pending(ref)
        |> WorkList.done(ref)

      assert WorkList.count(work_list) == 4
    end

    test "dropping pending work items", context do
      connect(context, max_work_list_size: 10)
      pause_mqtt_server(context)

      work_list = get_session_work_list()

      work_list =
        Enum.reduce(1..15, work_list, fn i, acc ->
          WorkList.push(
            acc,
            {{:publish, "foo", %{"msg" => "hello #{i}"}, [qos: 1]},
             [expiration: Expiration.expiration(:infinity)]}
          )
          |> WorkList.pending(make_ref())
        end)

      assert WorkList.count_pending(work_list) == 10
    end

    test "reset_pending work items", context do
      connect(context, max_work_list_size: 10)
      pause_mqtt_server(context)

      work_list = get_session_work_list()

      work_list =
        Enum.reduce(1..5, work_list, fn i, acc ->
          WorkList.push(
            acc,
            {{:publish, "foo", %{"msg" => "hello #{i}"}, [qos: 1]},
             [expiration: Expiration.expiration(:infinity)]}
          )
        end)

      ref = make_ref()

      work_list = WorkList.pending(work_list, ref)
      assert WorkList.count(work_list) == 4
      work_list = WorkList.reset_pending(work_list)
      assert WorkList.count(work_list) == 5
    end

    test "rebasing expiration" do
      time = Expiration.now()
      exp1 = Expiration.expiration(100)
      exp2 = Expiration.expiration(200)
      stop_time = time + 10
      assert Expiration.after?(exp2, exp1)
      restart_time = Enum.random(-10_000..10_000)
      ttl1 = Expiration.rebase_expiration(exp1, stop_time, restart_time)
      ttl2 = Expiration.rebase_expiration(exp2, stop_time, restart_time)
      assert Expiration.after?(exp2, exp1)
      assert ttl1 == restart_time + 90
      assert ttl2 <= restart_time + 190
    end
  end

  # Apologies for the mess after this point; these are helpers that
  # makes it easier to assert that a subscription has been placed, and
  # acknowledge that subscription; assert that a publish has been
  # made, etc
  defp setup_server(%{mqtt_server_pid: mqtt_server} = context) when is_pid(mqtt_server) do
    script = [
      {:receive, %Package.Connect{client_id: context.client_id}},
      {:send, %Package.Connack{status: :accepted, session_present: false}}
    ]

    {:ok, {ip, port}} = MqttServer.enact(mqtt_server, script)

    # Create a TCP transport for tortoise we can give to Jackalope as
    # its "server" specification
    {Tortoise311.Transport.Tcp, [host: ip, port: port]}
  end

  defp connect(%{client_id: client_id} = context, opts \\ []) do
    transport = setup_server(context)

    handler = Keyword.get(opts, :handler, JackalopeTest.TestHandler)
    initial_topics = Keyword.get(opts, :initial_topics)
    max_work_list_size = Keyword.get(opts, :max_work_list_size, 100)

    start_supervised!(
      {Jackalope,
       [
         server: transport,
         client_id: client_id,
         handler: handler,
         initial_topics: initial_topics,
         max_work_list_size: max_work_list_size,
         work_list_mod: @work_list_mod,
         data_dir: "/tmp"
       ]}
    )

    assert_receive {MqttServer, {:received, %Package.Connect{client_id: ^client_id}}}
    assert_receive {MqttServer, :completed}

    work_list = get_session_work_list()
    WorkList.remove_all(work_list)
    assert WorkList.empty?(work_list)
  end

  defp expect_publish(context, %Package.Publish{qos: 0} = publish) do
    # setup the expectation of a publish and assert that the server
    # received the message
    publish = json_encode_payload(publish)

    script = [{:receive, publish}]
    {:ok, _} = MqttServer.enact(context.mqtt_server_pid, script)

    fn ->
      assert_receive {MqttServer, {:received, received_publish = %Package.Publish{}}}, 500
      assert_receive {MqttServer, :completed}, 500
      received_publish
    end
  end

  defp expect_publish(context, %Package.Publish{qos: 1} = publish) do
    # setup the expectation of a publish, and acknowledge that
    # publish; assert that the server received the message
    publish = json_encode_payload(publish)

    script = [{:receive, publish}]
    {:ok, _} = MqttServer.enact(context.mqtt_server_pid, script)

    fn ->
      assert_receive {MqttServer, {:received, received_publish = %Package.Publish{}}}, 500
      assert_receive {MqttServer, :completed}, 500

      # acknowledge that message
      script = [{:send, %Package.Puback{identifier: received_publish.identifier}}]
      {:ok, _} = MqttServer.enact(context.mqtt_server_pid, script)
      assert_receive {MqttServer, :completed}, 500

      received_publish
    end
  end

  defp expect_publish(context, opts) do
    topic = Keyword.fetch!(opts, :topic)
    payload = Keyword.get(opts, :payload)
    qos = Keyword.get(opts, :qos, 0)

    expect_publish(context, %Package.Publish{
      topic: topic,
      qos: qos,
      payload: payload
    })
  end

  defp json_encode_payload(%Package.Publish{payload: nil} = keep), do: keep

  defp json_encode_payload(%Package.Publish{payload: data} = publish) do
    %Package.Publish{publish | payload: Jason.encode!(data)}
  end

  defp pause_mqtt_server(context) do
    {:ok, _} = MqttServer.enact(context.mqtt_server_pid, [:pause])
    Process.sleep(100)
  end
end
