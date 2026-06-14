defmodule CDPEx.ProtocolTest do
  use ExUnit.Case, async: true

  alias CDPEx.Protocol

  doctest Protocol

  defp decode(iodata), do: iodata |> IO.iodata_to_binary() |> Jason.decode!()

  describe "encode/4" do
    test "builds a command without a session id" do
      decoded = "Page.navigate" |> Protocol.encode(%{"url" => "u"}, 1) |> decode()
      assert decoded == %{"id" => 1, "method" => "Page.navigate", "params" => %{"url" => "u"}}
      refute Map.has_key?(decoded, "sessionId")
    end

    test "includes a session id when given" do
      decoded = "Runtime.enable" |> Protocol.encode(%{}, 2, "SID-1") |> decode()
      assert decoded["sessionId"] == "SID-1"
    end

    test "encodes empty params as an object" do
      assert %{"params" => params} = "Page.enable" |> Protocol.encode(%{}, 3) |> decode()
      assert params == %{}
    end
  end

  describe "classify/1" do
    test "ok reply" do
      assert Protocol.classify({:text, ~s({"id":10,"result":{"k":"v"}})}) ==
               {:reply, 10, nil, {:ok, %{"k" => "v"}}}
    end

    test "error reply returns the raw CDP error object" do
      frame = {:text, ~s({"id":11,"error":{"code":-32000,"message":"nope"}})}

      assert Protocol.classify(frame) ==
               {:reply, 11, nil, {:error, %{"code" => -32_000, "message" => "nope"}}}
    end

    test "event with params" do
      frame = {:text, ~s({"method":"Page.lifecycleEvent","params":{"name":"networkAlmostIdle"}})}

      assert Protocol.classify(frame) ==
               {:event, "Page.lifecycleEvent", nil, %{"name" => "networkAlmostIdle"}}
    end

    test "event without params defaults to an empty map" do
      assert Protocol.classify({:text, ~s({"method":"Inspector.detached"})}) ==
               {:event, "Inspector.detached", nil, %{}}
    end

    test "surfaces the sessionId from flattened-session frames" do
      reply = {:text, ~s({"id":5,"sessionId":"S1","result":{"ok":true}})}
      assert Protocol.classify(reply) == {:reply, 5, "S1", {:ok, %{"ok" => true}}}

      event =
        {:text, ~s({"method":"Page.lifecycleEvent","sessionId":"S1","params":{"name":"load"}})}

      assert Protocol.classify(event) ==
               {:event, "Page.lifecycleEvent", "S1", %{"name" => "load"}}
    end

    test "a reply is never misread as an event even if it lacks result/error" do
      # An id-bearing message with neither result nor error is not our concern;
      # it must not be classified as an event (no spurious subscriber fan-out).
      assert Protocol.classify({:text, ~s({"id":12})}) == :ignore
    end

    test "ping surfaces for pong handling" do
      assert Protocol.classify({:ping, "p"}) == {:ping, "p"}
    end

    test "close surfaces so the connection can shut down" do
      assert Protocol.classify({:close, 1000, "bye"}) == {:close, 1000, "bye"}
    end

    test "pong is ignored" do
      assert Protocol.classify({:pong, "p"}) == :ignore
    end

    test "malformed JSON is ignored, not raised" do
      assert Protocol.classify({:text, "{not json"}) == :ignore
    end
  end

  describe "evaluate_result/1" do
    test "string value" do
      assert Protocol.evaluate_result(%{"result" => %{"type" => "string", "value" => "<html>"}}) ==
               {:ok, "<html>"}
    end

    test "non-string values pass through" do
      assert Protocol.evaluate_result(%{"result" => %{"type" => "number", "value" => 42}}) ==
               {:ok, 42}

      assert Protocol.evaluate_result(%{"result" => %{"type" => "boolean", "value" => true}}) ==
               {:ok, true}
    end

    test "undefined becomes nil" do
      assert Protocol.evaluate_result(%{"result" => %{"type" => "undefined"}}) == {:ok, nil}
    end

    test "a thrown exception is an error, even if a result is also present" do
      result = %{"result" => %{"type" => "object"}, "exceptionDetails" => %{"text" => "Uncaught"}}

      assert {:error, {:evaluate_exception, %{"text" => "Uncaught"}}} =
               Protocol.evaluate_result(result)
    end

    test "unrecognised shape is an error" do
      assert {:error, {:unexpected_evaluate, %{}}} = Protocol.evaluate_result(%{})
    end

    test "an unserializableValue result (BigInt/NaN/Infinity/-0) is unserializable_value" do
      # Chrome returns these with `unserializableValue` and no by-value `value`
      # key under returnByValue, so they get the dedicated recoverable tag rather
      # than {:ok, _} or the unrecognized-envelope catch-all. `type` mirrors what
      # real Chrome reports (bigint for 10n, number for the rest); the clause keys
      # only off `unserializableValue`, and the tag carries that raw string.
      for {type, uv} <- [
            {"bigint", "10n"},
            {"number", "NaN"},
            {"number", "Infinity"},
            {"number", "-0"}
          ] do
        result = %{"result" => %{"type" => type, "unserializableValue" => uv}}
        assert {:error, {:unserializable_value, ^uv}} = Protocol.evaluate_result(result)
      end
    end
  end

  describe "parse_ws_url/1" do
    test "splits scheme, host, port, and path" do
      assert Protocol.parse_ws_url("ws://127.0.0.1:9222/devtools/browser/abc-123") ==
               {"ws", "127.0.0.1", 9222, "/devtools/browser/abc-123"}
    end

    test "handles a page target path" do
      assert Protocol.parse_ws_url("ws://localhost:5000/devtools/page/DEADBEEF") ==
               {"ws", "localhost", 5000, "/devtools/page/DEADBEEF"}
    end

    test "accepts wss:// and reports the scheme" do
      assert Protocol.parse_ws_url("wss://example.com:443/devtools/browser/abc") ==
               {"wss", "example.com", 443, "/devtools/browser/abc"}
    end

    test "rejects a non-ws(s) scheme" do
      assert_raise ArgumentError, fn -> Protocol.parse_ws_url("http://127.0.0.1:9222/x") end
    end
  end

  test "prevent_alerts_js/0 overrides the three modal dialog functions" do
    js = Protocol.prevent_alerts_js()
    assert js =~ "window.alert"
    assert js =~ "window.confirm"
    assert js =~ "window.prompt"
  end
end
