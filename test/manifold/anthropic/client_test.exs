defmodule Manifold.Anthropic.ClientTest do
  use ExUnit.Case, async: false

  alias Manifold.Anthropic.Client

  # Pure, despite exercising real HTTP-client code: `plug: {Req.Test, name}` swaps
  # Req's transport for a stub invoked in-process, so nothing here opens a socket or
  # spawns an OS process — no `test/smoke` justification needed. See CLAUDE.md's tiering
  # and the moduledoc's own note that `:plug` never appears outside a test. Backend
  # config (`:api_key`/`:model`/`:plug`) lives in `Application.env`, so this suite is
  # `async: false` — the same reason `Manifold.ModelTest` is.

  setup do
    on_exit(fn -> Application.delete_env(:manifold, :model) end)
    :ok
  end

  describe "completion/2" do
    test "sends the API key as a header, never a query param or path segment" do
      Req.Test.stub(:auth, fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-api-key") == ["sk-test"]
        assert Plug.Conn.get_req_header(conn, "anthropic-version") == ["2023-06-01"]
        assert conn.query_string == ""
        json_response(conn, 200, %{"content" => [%{"type" => "text", "text" => "hi"}]})
      end)

      with_backend([api_key: "sk-test", model: "claude-x", plug: {Req.Test, :auth}], fn ->
        assert Client.completion("hello") == {:ok, "hi"}
      end)
    end

    test "concatenates only \"text\" content blocks, skipping tool_use and friends" do
      Req.Test.stub(:mixed_blocks, fn conn ->
        json_response(conn, 200, %{
          "content" => [
            %{"type" => "text", "text" => "Hello, "},
            %{"type" => "tool_use", "id" => "toolu_1", "name" => "lookup", "input" => %{}},
            %{"type" => "text", "text" => "world."}
          ]
        })
      end)

      with_backend([api_key: "sk-test", model: "claude-x", plug: {Req.Test, :mixed_blocks}], fn ->
        assert Client.completion("hi") == {:ok, "Hello, world."}
      end)
    end

    test "defaults max_tokens to 512 and temperature to 0.7, matching Llama.Client" do
      Req.Test.stub(:defaults, fn conn ->
        assert request_body(conn)["max_tokens"] == 512
        assert request_body(conn)["temperature"] == 0.7
        json_response(conn, 200, %{"content" => [%{"type" => "text", "text" => "ok"}]})
      end)

      with_backend([api_key: "sk-test", model: "claude-x", plug: {Req.Test, :defaults}], fn ->
        assert Client.completion("hello") == {:ok, "ok"}
      end)
    end

    test "n_predict and temperature opts override the defaults, mapped to max_tokens" do
      Req.Test.stub(:overrides, fn conn ->
        assert request_body(conn)["max_tokens"] == 64
        assert request_body(conn)["temperature"] == 0.1
        json_response(conn, 200, %{"content" => [%{"type" => "text", "text" => "ok"}]})
      end)

      with_backend([api_key: "sk-test", model: "claude-x", plug: {Req.Test, :overrides}], fn ->
        assert Client.completion("hello", n_predict: 64, temperature: 0.1) == {:ok, "ok"}
      end)
    end

    test "passes :system, :tools and :tool_choice straight through to the request body" do
      Req.Test.stub(:passthrough, fn conn ->
        body = request_body(conn)
        assert body["system"] == "be terse"
        assert body["tools"] == [%{"name" => "lookup"}]
        assert body["tool_choice"] == %{"type" => "auto"}
        json_response(conn, 200, %{"content" => [%{"type" => "text", "text" => "ok"}]})
      end)

      opts = [
        system: "be terse",
        tools: [%{"name" => "lookup"}],
        tool_choice: %{"type" => "auto"}
      ]

      with_backend([api_key: "sk-test", model: "claude-x", plug: {Req.Test, :passthrough}], fn ->
        assert Client.completion("hello", opts) == {:ok, "ok"}
      end)
    end

    test "ignores :grammar — this backend has no GBNF primitive, per the ADR" do
      Req.Test.stub(:ignores_grammar, fn conn ->
        refute Map.has_key?(request_body(conn), "grammar")
        json_response(conn, 200, %{"content" => [%{"type" => "text", "text" => "ok"}]})
      end)

      with_backend([api_key: "sk-test", model: "claude-x", plug: {Req.Test, :ignores_grammar}], fn ->
        assert Client.completion("hello", grammar: "root ::= \"x\"") == {:ok, "ok"}
      end)
    end

    test "maps 429 to {:rate_limited, retry_after} from the header, not the body" do
      Req.Test.stub(:rate_limited, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "12")
        |> json_response(429, %{"error" => %{"type" => "rate_limit_error", "message" => "slow down"}})
      end)

      with_backend([api_key: "sk-test", model: "claude-x", plug: {Req.Test, :rate_limited}], fn ->
        assert Client.completion("hello") == {:error, {:rate_limited, 12}}
      end)
    end

    test "maps a well-formed Anthropic error body to {:api_error, status, type, message}" do
      Req.Test.stub(:api_error, fn conn ->
        json_response(conn, 500, %{"error" => %{"type" => "api_error", "message" => "boom"}})
      end)

      with_backend([api_key: "sk-test", model: "claude-x", plug: {Req.Test, :api_error}], fn ->
        assert Client.completion("hello") == {:error, {:api_error, 500, "api_error", "boom"}}
      end)
    end

    test "falls back to {:http, status, body} for a non-JSON error response" do
      Req.Test.stub(:opaque_error, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.send_resp(503, "<html>Service Unavailable</html>")
      end)

      with_backend([api_key: "sk-test", model: "claude-x", plug: {Req.Test, :opaque_error}], fn ->
        assert Client.completion("hello") == {:error, {:http, 503, "<html>Service Unavailable</html>"}}
      end)
    end

    test "passes a transport-level error straight through, same as Llama.Client" do
      Req.Test.stub(:transport_error, fn conn -> Req.Test.transport_error(conn, :timeout) end)

      with_backend([api_key: "sk-test", model: "claude-x", plug: {Req.Test, :transport_error}], fn ->
        assert {:error, %Req.TransportError{reason: :timeout}} = Client.completion("hello")
      end)
    end

    test "fails fast with {:missing_config, :api_key} rather than calling out with no credentials" do
      with_backend([model: "claude-x"], fn ->
        assert Client.completion("hello") == {:error, {:missing_config, :api_key}}
      end)
    end

    test "fails fast with {:missing_config, :model} rather than calling out with no model" do
      with_backend([api_key: "sk-test"], fn ->
        assert Client.completion("hello") == {:error, {:missing_config, :model}}
      end)
    end
  end

  describe "stream/3" do
    test "invokes on_delta per text_delta and returns the concatenated text" do
      Req.Test.stub(:stream_ok, fn conn ->
        conn
        |> Plug.Conn.send_chunked(200)
        |> chunk!(delta_event("Hel"))
        |> chunk!(delta_event("lo"))
        |> chunk!(stop_event())
      end)

      with_backend([api_key: "sk-test", model: "claude-x", plug: {Req.Test, :stream_ok}], fn ->
        assert Client.stream("hello", [], collector()) == {:ok, "Hello"}
        assert drain_deltas() == "Hello"
      end)
    end

    test "ignores structural events (message_start, ping, content_block_start, ...)" do
      Req.Test.stub(:stream_structural, fn conn ->
        conn
        |> Plug.Conn.send_chunked(200)
        |> chunk!("event: message_start\ndata: #{Jason.encode!(%{"type" => "message_start"})}\n\n")
        |> chunk!("event: ping\ndata: #{Jason.encode!(%{"type" => "ping"})}\n\n")
        |> chunk!(delta_event("ok"))
      end)

      with_backend([api_key: "sk-test", model: "claude-x", plug: {Req.Test, :stream_structural}], fn ->
        assert Client.stream("hello", [], collector()) == {:ok, "ok"}
      end)
    end

    test "a mid-stream error event surfaces as {:api_error, nil, type, message}" do
      Req.Test.stub(:stream_error, fn conn ->
        conn
        |> Plug.Conn.send_chunked(200)
        |> chunk!(delta_event("partial"))
        |> chunk!(error_event("overloaded_error", "Overloaded"))
      end)

      with_backend([api_key: "sk-test", model: "claude-x", plug: {Req.Test, :stream_error}], fn ->
        assert Client.stream("hello", [], collector()) ==
                 {:error, {:api_error, nil, "overloaded_error", "Overloaded"}}
      end)
    end

    test "an HTTP-status error (never reaching SSE) still maps like completion/2's" do
      Req.Test.stub(:stream_http_error, fn conn ->
        json_response(conn, 500, %{"error" => %{"type" => "api_error", "message" => "boom"}})
      end)

      with_backend([api_key: "sk-test", model: "claude-x", plug: {Req.Test, :stream_http_error}], fn ->
        assert Client.stream("hello", [], collector()) == {:error, {:api_error, 500, "api_error", "boom"}}
      end)
    end

    test "fails fast with {:missing_config, :api_key} before ever streaming" do
      with_backend([model: "claude-x"], fn ->
        assert Client.stream("hello", [], collector()) == {:error, {:missing_config, :api_key}}
      end)
    end
  end

  # --- test helpers ------------------------------------------------------------

  defp json_response(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  defp request_body(conn) do
    {:ok, raw, _conn} = Plug.Conn.read_body(conn)
    Jason.decode!(raw)
  end

  defp chunk!(conn, data) do
    {:ok, conn} = Plug.Conn.chunk(conn, data)
    conn
  end

  defp delta_event(text) do
    delta = %{"type" => "content_block_delta", "delta" => %{"type" => "text_delta", "text" => text}}
    "event: content_block_delta\ndata: #{Jason.encode!(delta)}\n\n"
  end

  defp stop_event, do: "event: message_stop\ndata: #{Jason.encode!(%{"type" => "message_stop"})}\n\n"

  defp error_event(type, message) do
    "event: error\ndata: #{Jason.encode!(%{"type" => "error", "error" => %{"type" => type, "message" => message}})}\n\n"
  end

  defp collector do
    parent = self()
    fn chunk -> send(parent, {:delta, chunk}) end
  end

  defp drain_deltas(acc \\ []) do
    receive do
      {:delta, chunk} -> drain_deltas([chunk | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.join()
    end
  end

  defp with_backend(opts, fun) do
    Application.put_env(:manifold, :model, {Client, opts})
    fun.()
  end
end
