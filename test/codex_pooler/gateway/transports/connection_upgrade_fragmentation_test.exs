defmodule CodexPooler.Gateway.Transports.ConnectionUpgradeFragmentationTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.ConnectionUpgrade

  @timeouts %{connect_timeout_ms: 1_000}

  test "retains a successful upgrade status across separate TCP reads" do
    {task, peer} = fragmented_upgrade(101)
    assert_receive {:status_sent, ^peer}
    await_status_consumed(task.pid)
    send(peer, :finish)
    assert {:ok, state} = Task.await(task)
    assert state.generation == 1
    assert {"upgrade", "websocket"} in state.headers
  end

  test "retains an upstream refusal status instead of fabricating an invalid upgrade" do
    {task, peer} = fragmented_upgrade(403)
    assert_receive {:status_sent, ^peer}
    await_status_consumed(task.pid)
    send(peer, :finish)
    assert {:error, {:websocket_upgrade_failed, 403, headers}, _state} = Task.await(task)
    assert {"content-length", "0"} in headers
  end

  test "a stalled fragmented upgrade exhausts its bounded deadline" do
    {task, peer} = fragmented_upgrade(101)
    assert_receive {:status_sent, ^peer}
    await_status_consumed(task.pid)
    assert {:error, :upstream_websocket_upgrade_timeout, _state} = Task.await(task)
  end

  defp fragmented_upgrade(status) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)
    parent = self()

    peer = spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listener)
      request = read_headers(socket, "")
      [_, key] = Regex.run(~r/sec-websocket-key: ([^\r]+)/i, request)
      accept = :crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11") |> Base.encode64()
      :ok = :gen_tcp.send(socket, "HTTP/1.1 #{status} Test\r\n")
      send(parent, {:status_sent, self()})

      receive do
        :finish ->
          headers = if status == 101 do
            "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n"
          else
            "Content-Length: 0\r\n\r\n"
          end
          :gen_tcp.send(socket, headers)
          :gen_tcp.recv(socket, 0, 2_000)
      after
        2_000 -> :ok
      end

      :gen_tcp.close(socket)
    end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      if Process.alive?(peer), do: Process.exit(peer, :kill)
    end)

    task = Task.async(fn ->
      result = ConnectionUpgrade.connect_state(%{generation: 0}, :test,
        "http://127.0.0.1:#{port}/responses", [], @timeouts, nil)
      case result do
        {:ok, %{conn: conn}} -> Mint.HTTP.close(conn)
        {:error, _, %{conn: conn}} -> Mint.HTTP.close(conn)
        _ -> :ok
      end
      result
    end)

    {task, peer}
  end

  defp read_headers(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      acc
    else
      {:ok, bytes} = :gen_tcp.recv(socket, 0, 2_000)
      read_headers(socket, acc <> bytes)
    end
  end

  # Wait for the parser to consume the status-only batch before releasing headers.
  # Both the old and patched receive loops are accepted so this test proves red/green.
  defp await_status_consumed(pid, attempts \\ 100)
  defp await_status_consumed(_pid, 0), do: flunk("upgrade did not consume the status batch")
  defp await_status_consumed(pid, attempts) do
    case Process.info(pid, :current_stacktrace) do
      {:current_stacktrace, stack} ->
        if Enum.any?(stack, fn {m, f, a, _} ->
          m == ConnectionUpgrade and f == :await_upgrade and a in [4, 5]
        end) do
          # A short delay lets the already-sent status reach the waiting socket.
          Process.sleep(50)
        else
          Process.sleep(5)
          await_status_consumed(pid, attempts - 1)
        end
      _ -> flunk("upgrade task exited early")
    end
  end
end
