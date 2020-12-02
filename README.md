# Jackalope

[![CircleCI](https://circleci.com/gh/smartrent/jackalope.svg?style=svg)](https://circleci.com/gh/smartrent/jackalope)
[![Hex version](https://img.shields.io/hexpm/v/jackalope.svg "Hex version")](https://hex.pm/packages/jackalope)

<!-- MDOC !-->

`Jackalope` is an opinionated MQTT library that simplifies the use of
[`Tortoise MQTT`](https://hex.pm/packages/tortoise) with cloud IoT
services.

Jackalope aims to make an interface that:

- Ensure that important messages are delivered to the broker, by
  having a local "post office" and tracking the in flight messages,
  and implementing a concept of ttl (time to live) on the messages
  placed in the mailbox; ensuring the "request to unlock the door"
  won't happen two hours later when the MQTT connection finally
  reconnects. This allows Jackalope to accept publish and
  subscription requests while the connection is down.

- Makes it impossible (or at least hard) to do things that AWS IoT
  and other popular services do not support; such as publishing a
  message or subscribing to a topic filter with a greater quality of
  service than allowed, or publishing a message with the retain flag
  set

- Makes it easy to connect to AWS IoT with the correct encryption
  enabled

Besides this Jackalope aims to provide helpers for local testing,
allowing you to test your application without having a connection to
AWS; Jackalope should take care of that.

## Usage

The `Jackalope` module implements a `start_link/1` function; use this
to start `Jackalope` as part of your application supervision tree. If
properly supervised it will allow you to start and stop `Jackalope`
with the part the application that needs MQTT connectivity.
`Jackalope` is configured using a keyword list, consult the
`Jackalope.start_link/1` documentation for information on the
available option values.

Once `Jackalope` is running it is possible to subscribe, unsubscribe,
and publish messages to the broker; in addition to this there are some
connection specific functionality is exposed, allowing us to ask for
the connection status, and request a connection reconnect.

- `Jackalope.subscribe(topic)` request a subscription to a specific
  topic. The topic will be added to the list of topics `Jackalope`
  will ensure we are subscribed to.

- `Jackalope.unsubscribe(topic)` will request an unsubscribe from a
  specific topic and remove the topic from the list of topics
  `Jackalope` ensure are subscribed to.

- `Jackalope.publish(topic, payload)` will publish a message to the
  MQTT broker;

- `Jackalope.reconnect()` will disconnect from the broker and
  reconnect; this is useful if the device changes network connection.

Please see the documentation for each of the functions for more
information on usage; especially the subscribe and publish functions
accepts options such as setting quality of service and time to live.

<!-- MDOC !-->

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be
installed by adding `jackalope` to your list of dependencies in
`mix.exs`:

```elixir
def deps do
  [
    {:jackalope, "~> 0.1.0"}
  ]
end

```
## Connecting to AWS IoT

Assuming an app named `YourApp` connecting via SSL to AWS IoT...
### mix.exs

```
defmodule YourApp.MixProject do
  use Mix.Project
    
  defp deps do
    [
      {:jackalope, "~> 0.1.0"},
      {:x509, "~> 0.5"}, # Needed to process certificates
      ...
    ]
  end
  
  # ...

end
```
### config.exs

```
# Edit to fit your AWS IoT configuration

config :your_app,
  # Edit your AWS Service Endpoint
  mqtt_host: "???????????.iot.us-east-1.amazonaws.com",
  mqtt_port: 443,
  mqtt_api_version: "1.0",
  # Edit to match your AWS Service Endpoint
  server_name_indication: '*.iot.us-east-1.amazonaws.com',
  # The list of protocols supported by the client to be sent to the server to be used 
  # for an Application-Layer Protocol Negotiation (ALPN)
  alpn_advertised_protocols: ["x-amzn-mqtt-ca"],
  # Keys for Amazon Trust Services Endpoints
  aws_root_ca1: """
  -----BEGIN CERTIFICATE-----
  MIIDQTCCAimgAwIBAgITBmyfz5m/jAo54vB4ikPmljZbyjANBgkqhkiG9w0BAQsF
  ADA5MQswCQYDVQQGEwJVUzEPMA0GA1UEChMGQW1hem9uMRkwFwYDVQQDExBBbWF6
  b24gUm9vdCBDQSAxMB4XDTE1MDUyNjAwMDAwMFoXDTM4MDExNzAwMDAwMFowOTEL
  MAkGA1UEBhMCVVMxDzANBgNVBAoTBkFtYXpvbjEZMBcGA1UEAxMQQW1hem9uIFJv
  b3QgQ0EgMTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBALJ4gHHKeNXj
  ca9HgFB0fW7Y14h29Jlo91ghYPl0hAEvrAIthtOgQ3pOsqTQNroBvo3bSMgHFzZM
  9O6II8c+6zf1tRn4SWiw3te5djgdYZ6k/oI2peVKVuRF4fn9tBb6dNqcmzU5L/qw
  IFAGbHrQgLKm+a/sRxmPUDgH3KKHOVj4utWp+UhnMJbulHheb4mjUcAwhmahRWa6
  VOujw5H5SNz/0egwLX0tdHA114gk957EWW67c4cX8jJGKLhD+rcdqsq08p8kDi1L
  93FcXmn/6pUCyziKrlA4b9v7LWIbxcceVOF34GfID5yHI9Y/QCB/IIDEgEw+OyQm
  jgSubJrIqg0CAwEAAaNCMEAwDwYDVR0TAQH/BAUwAwEB/zAOBgNVHQ8BAf8EBAMC
  AYYwHQYDVR0OBBYEFIQYzIU07LwMlJQuCFmcx7IQTgoIMA0GCSqGSIb3DQEBCwUA
  A4IBAQCY8jdaQZChGsV2USggNiMOruYou6r4lK5IpDB/G/wkjUu0yKGX9rbxenDI
  U5PMCCjjmCXPI6T53iHTfIUJrU6adTrCC2qJeHZERxhlbI1Bjjt/msv0tadQ1wUs
  N+gDS63pYaACbvXy8MWy7Vu33PqUXHeeE6V/Uq2V8viTO96LXFvKWlJbYK8U90vv
  o/ufQJVtMVT8QtPHRh8jrdkPSHCa2XV4cdFyQzR1bldZwgJcJmApzyMZFo6IQ6XU
  5MsI+yMRQ+hDKXJioaldXgjUkK642M4UwtBV8ob2xJNDd2ZhwLnoQdeXeGADbkpy
  rqXRfboQnoZsG4q5WTP468SQvvG5
  -----END CERTIFICATE-----
  """,
  aws_root_ca2: """
  -----BEGIN CERTIFICATE-----
  MIIFQTCCAymgAwIBAgITBmyf0pY1hp8KD+WGePhbJruKNzANBgkqhkiG9w0BAQwF
  ADA5MQswCQYDVQQGEwJVUzEPMA0GA1UEChMGQW1hem9uMRkwFwYDVQQDExBBbWF6
  b24gUm9vdCBDQSAyMB4XDTE1MDUyNjAwMDAwMFoXDTQwMDUyNjAwMDAwMFowOTEL
  MAkGA1UEBhMCVVMxDzANBgNVBAoTBkFtYXpvbjEZMBcGA1UEAxMQQW1hem9uIFJv
  b3QgQ0EgMjCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAK2Wny2cSkxK
  gXlRmeyKy2tgURO8TW0G/LAIjd0ZEGrHJgw12MBvIITplLGbhQPDW9tK6Mj4kHbZ
  W0/jTOgGNk3Mmqw9DJArktQGGWCsN0R5hYGCrVo34A3MnaZMUnbqQ523BNFQ9lXg
  1dKmSYXpN+nKfq5clU1Imj+uIFptiJXZNLhSGkOQsL9sBbm2eLfq0OQ6PBJTYv9K
  8nu+NQWpEjTj82R0Yiw9AElaKP4yRLuH3WUnAnE72kr3H9rN9yFVkE8P7K6C4Z9r
  2UXTu/Bfh+08LDmG2j/e7HJV63mjrdvdfLC6HM783k81ds8P+HgfajZRRidhW+me
  z/CiVX18JYpvL7TFz4QuK/0NURBs+18bvBt+xa47mAExkv8LV/SasrlX6avvDXbR
  8O70zoan4G7ptGmh32n2M8ZpLpcTnqWHsFcQgTfJU7O7f/aS0ZzQGPSSbtqDT6Zj
  mUyl+17vIWR6IF9sZIUVyzfpYgwLKhbcAS4y2j5L9Z469hdAlO+ekQiG+r5jqFoz
  7Mt0Q5X5bGlSNscpb/xVA1wf+5+9R+vnSUeVC06JIglJ4PVhHvG/LopyboBZ/1c6
  +XUyo05f7O0oYtlNc/LMgRdg7c3r3NunysV+Ar3yVAhU/bQtCSwXVEqY0VThUWcI
  0u1ufm8/0i2BWSlmy5A5lREedCf+3euvAgMBAAGjQjBAMA8GA1UdEwEB/wQFMAMB
  Af8wDgYDVR0PAQH/BAQDAgGGMB0GA1UdDgQWBBSwDPBMMPQFWAJI/TPlUq9LhONm
  UjANBgkqhkiG9w0BAQwFAAOCAgEAqqiAjw54o+Ci1M3m9Zh6O+oAA7CXDpO8Wqj2
  LIxyh6mx/H9z/WNxeKWHWc8w4Q0QshNabYL1auaAn6AFC2jkR2vHat+2/XcycuUY
  +gn0oJMsXdKMdYV2ZZAMA3m3MSNjrXiDCYZohMr/+c8mmpJ5581LxedhpxfL86kS
  k5Nrp+gvU5LEYFiwzAJRGFuFjWJZY7attN6a+yb3ACfAXVU3dJnJUH/jWS5E4ywl
  7uxMMne0nxrpS10gxdr9HIcWxkPo1LsmmkVwXqkLN1PiRnsn/eBG8om3zEK2yygm
  btmlyTrIQRNg91CMFa6ybRoVGld45pIq2WWQgj9sAq+uEjonljYE1x2igGOpm/Hl
  urR8FLBOybEfdF849lHqm/osohHUqS0nGkWxr7JOcQ3AWEbWaQbLU8uz/mtBzUF+
  fUwPfHJ5elnNXkoOrJupmHN5fLT0zLm4BwyydFy4x2+IoZCn9Kr5v2c69BoVYh63
  n749sSmvZ6ES8lgQGVMDMBu4Gon2nL2XA46jCfMdiyHxtN/kHNGfZQIG6lzWE7OE
  76KlXIx3KadowGuuQNKotOrN8I1LOJwZmhsoVLiJkO/KdYE+HvJkJMcYr07/R54H
  9jVlpNMKVv/1F2Rs76giJUmTtt8AF9pYfl3uxRuw0dFfIRDH+fO6AgonB8Xx1sfT
  4PsJYGw=
  -----END CERTIFICATE-----
  """
```

### supervisor.ex

```
defmodule YourApp.Supervisor do
  @moduledoc "YourApp's top supervisor."

  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  def init(_init_args) do

    children = [
      {Jackalope,
       [
         handler: YourApp,
         client_id: "your_client_id",
         server: YourApp.mqtt_server_options(), # <========================
         initial_topics: [],
         # Any properly formed topic and payload will do
         last_will: [
           topic: "goodbye",
           payload: "{\"msg\": \"Last will message\"}",
           qos: 1
         ]
       ]},
      YourApp
    ]

    opts = [strategy: :one_for_one]
    Supervisor.init(children, opts)
  end
end
```
### your_app.ex

```
defmodule YourApp do
 
  @doc "Produce the Tortoise MQTT server options to connect to AWS IoT via SSL"
  def mqtt_server_options() do
    {cert, key, cacerts} = security()

    {
      Tortoise.Transport.SSL,
      verify: :verify_peer,
      host: mqtt_host(),
      port: mqtt_port(),
      alpn_advertised_protocols: alpn_advertised_protocols(),
      server_name_indication: server_name_indication(),
      cert: cert,
      key: key,
      cacerts: cacerts,
      versions: [:"tlsv1.2"],
      partial_chain: &partial_chain/1
    }
  end
  
  # ...

  defp mqtt_host(), do: Application.get_env(:your_app, :mqtt_host)
  
  defp mqtt_port(), do: Application.get_env(:your_app, :mqtt_port)
  
  defp server_name_indication(), do: Application.get_env(:your_app, :server_name_indication)

  defp alpn_advertised_protocols(), do: Application.get_env(:your_app, :alpn_advertised_protocols)

  defp security() do
    # Certificate to DER format
    aws_root_certs = [
      X509.Certificate.to_der(aws_root_ca1()),
      X509.Certificate.to_der(aws_root_ca2())
    ]


    signer_cert = X509.Certificate.to_der(your_signer_cert())
    cert = X509.Certificate.to_der(your_key_cert())
    # A key map for passing a private key to ssl_opts
    # See https://erlang.org/doc/man/ssl.html#type-key
    key = {'RSAPrivateKey', X509.Certificate.to_der(your_private_key())}
    cacerts = [signer_cert] ++ aws_root_certs
    {cert, key, cacerts}
  end

  defp your_signer_cert(), do: "" # Yours to define

  defp your_key_cert(), do: "" # Yours to define

  defp your_private_key(), do: "" # Yours to define

  defp aws_root_ca1() do
    Application.get_env(:your_app, :aws_root_ca1)
    # OTPCertificate
    |> X509.Certificate.from_pem!()
  end

  defp aws_root_ca2() do
    Application.get_env(:your_app, :aws_root_ca2)
    # OTPCertificate
    |> X509.Certificate.from_pem!()
  end

  defp partial_chain(server_certs) do
    # Note that the follwing certificates are in OTPCertificate format
    aws_root_certs = [aws_root_ca1(), aws_root_ca2()]

    Enum.reduce_while(
      aws_root_certs,
      :unknown_ca,
      fn aws_root_ca, unk_ca ->
        certificate_subject = X509.Certificate.extension(aws_root_ca, :subject_key_identifier)

        case find_partial_chain(certificate_subject, server_certs) do
          {:trusted_ca, _} = result -> {:halt, result}
          :unknown_ca -> {:cont, unk_ca}
        end
      end
    )
  end

  defp find_partial_chain(_root_subject, []) do
    :unknown_ca
  end

  defp find_partial_chain(root_subject, [h | t]) do
    cert = X509.Certificate.from_der!(h)
    cert_subject = X509.Certificate.extension(cert, :subject_key_identifier)

    if cert_subject == root_subject do
      {:trusted_ca, h}
    else
      find_partial_chain(root_subject, t)
    end
  end
    
 end
```