defmodule JackalopeTest do
  use ExUnit.Case, async: false
  doctest Jackalope

  alias JackalopeTest.ScriptedMqttServer, as: MqttServer
  alias Tortoise311.Package

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
                 handler: JackalopeTest.TestHandler
               )

      assert_receive {MqttServer, {:received, %Package.Connect{}}}

      assert is_pid(pid)
      assert Process.alive?(pid)

      assert_receive {MqttServer, :completed}, 200

      assert %{subscriptions: %{}} = Jackalope.Session.status()
    end

    test "connect to a MQTT server with initial subscribe topics (tcp)", context do
      # When we connect with a initial topics list set we will expect
      # a subscribe package on the server side after we connect;
      {:ok, _pid} = connect(context, initial_topics: ["foo/bar"])
      {:ok, subscribe} = expect_subscribe(context, [{"foo/bar", 1}])
      :ok = acknowledge_subscribe(context, subscribe, [{:ok, 1}])
    end
  end

  describe "publish/3" do
    test "publish with QoS=0", context do
      _ = connect(context)

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
      _ = connect(context)

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

  describe "subscribe/2" do
    test "subscribe to a topic filter with QoS=0", context do
      _ = connect(context)
      assert :ok = Jackalope.subscribe("foo/bar", qos: 0)
      {:ok, subscribe} = expect_subscribe(context, [{"foo/bar", 0}])
      :ok = acknowledge_subscribe(context, subscribe, [{:ok, 0}])
    end

    test "subscribe to a topic filter with QoS=1", context do
      _ = connect(context)
      assert :ok = Jackalope.subscribe("foo/bar", qos: 1)
      {:ok, subscribe} = expect_subscribe(context, [{"foo/bar", 1}])
      :ok = acknowledge_subscribe(context, subscribe, [{:ok, 1}])
    end
  end

  describe "unsubscribe/2" do
    test "unsubscribe from a topic filter", context do
      _ = connect(context)
      assert :ok = Jackalope.unsubscribe("foo/bar")
      {:ok, unsubscribe} = expect_unsubscribe(context, ["foo/bar"])
      :ok = acknowledge_unsubscribe(context, unsubscribe)
    end
  end

  describe "bounded work list" do
    test "dropping work orders", context do
      _ = connect(context, max_work_list_size: 10)

      for i <- 1..15 do
        assert :ok = Jackalope.publish("foo", %{"msg" => "hello #{i}"}, qos: 1)
      end

      work_list = Jackalope.Session.status() |> Map.fetch!(:work_list)
      assert Enum.count(work_list) == 10
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
    # Timing issue hack: Make sure the Session is fully terminated before we reconnect
    # and have the Jackelope supervisor initiated another of the same name
    kill_session()

    result =
      Jackalope.start_link(
        server: transport,
        client_id: client_id,
        handler: handler,
        initial_topics: initial_topics,
        max_work_list_size: max_work_list_size
      )

    pid =
      case result do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

    assert is_pid(pid)

    assert_receive {MqttServer, {:received, %Package.Connect{client_id: ^client_id}}}
    assert_receive {MqttServer, :completed}
    {:ok, pid}
  end

  defp kill_session() do
    GenServer.stop(Jackalope.Session, :shutdown)
  catch
    :exit, _ -> :ok
  end

  defp expect_publish(context, %Package.Publish{qos: 0} = publish) do
    # setup the expectation of a publish and assert that the server
    # received the message
    publish = json_encode_payload(publish)

    script = [{:receive, publish}]
    {:ok, _} = MqttServer.enact(context.mqtt_server_pid, script)

    fn ->
      assert_receive {MqttServer, {:received, received_publish = %Package.Publish{}}}
      assert_receive {MqttServer, :completed}
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
      assert_receive {MqttServer, {:received, received_publish = %Package.Publish{}}}
      assert_receive {MqttServer, :completed}

      # acknowledge that message
      script = [{:send, %Package.Puback{identifier: received_publish.identifier}}]
      {:ok, _} = MqttServer.enact(context.mqtt_server_pid, script)
      assert_receive {MqttServer, :completed}

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

  defp expect_subscribe(context, %Package.Subscribe{} = subscribe) do
    # setup the expectation that the server will receive a subscribe
    # package from the client
    script = [{:receive, subscribe}]
    {:ok, _} = MqttServer.enact(context.mqtt_server_pid, script)
    assert_receive {MqttServer, {:received, package = %Package.Subscribe{}}}
    assert_receive {MqttServer, :completed}

    {:ok, package}
  end

  defp expect_subscribe(context, [{topic, qos} | _] = subscribe_topics)
       when is_integer(qos) and is_binary(topic) do
    subscribe = %Package.Subscribe{topics: subscribe_topics}
    expect_subscribe(context, subscribe)
  end

  defp acknowledge_subscribe(context, %Package.Subscribe{identifier: id, topics: topics}, acks)
       when not is_nil(id) and length(topics) == length(acks) do
    suback = %Package.Suback{identifier: id, acks: acks}
    script = [{:send, suback}]
    {:ok, _} = MqttServer.enact(context.mqtt_server_pid, script)
    # expect the scripted server to dispatch the suback
    assert_receive {MqttServer, :completed}
    :ok
  end

  defp expect_unsubscribe(context, %Package.Unsubscribe{} = unsubscribe) do
    # setup the expectation that the server will receive a unsubscribe
    # package from the client
    script = [{:receive, unsubscribe}]
    {:ok, _} = MqttServer.enact(context.mqtt_server_pid, script)
    assert_receive {MqttServer, {:received, package = %Package.Unsubscribe{}}}
    assert_receive {MqttServer, :completed}

    {:ok, package}
  end

  defp expect_unsubscribe(context, [topic_filter | _] = unsubscribe_topics)
       when is_binary(topic_filter) do
    unsubscribe = %Package.Unsubscribe{topics: unsubscribe_topics}
    expect_unsubscribe(context, unsubscribe)
  end

  defp acknowledge_unsubscribe(context, %Package.Unsubscribe{identifier: id})
       when not is_nil(id) do
    unsuback = %Package.Unsuback{identifier: id}
    script = [{:send, unsuback}]
    {:ok, _} = MqttServer.enact(context.mqtt_server_pid, script)
    # expect the scripted server to dispatch the suback
    assert_receive {MqttServer, :completed}
    :ok
  end
end
