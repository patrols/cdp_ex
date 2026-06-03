defmodule CDPEx.FetchTest do
  use ExUnit.Case, async: true

  alias CDPEx.Connection
  alias CDPEx.FakeCDP
  alias CDPEx.Fetch

  @creds [username: "u", password: "p"]

  describe "auth_decision/5" do
    test "provides credentials for a matching challenge and records the attempt" do
      {response, attempts} = Fetch.auth_decision(:any, %{}, "R1", %{"source" => "Server"}, @creds)

      assert response == %{
               "response" => "ProvideCredentials",
               "username" => "u",
               "password" => "p"
             }

      assert attempts == %{"R1" => 1}
    end

    test "cancels on the second challenge for the same request (rejected credentials)" do
      {response, attempts} =
        Fetch.auth_decision(:any, %{"R1" => 1}, "R1", %{"source" => "Server"}, @creds)

      assert response == %{"response" => "CancelAuth"}
      refute Map.has_key?(attempts, "R1")
    end

    test "the :proxy filter answers only Proxy challenges" do
      assert {%{"response" => "Default"}, %{}} =
               Fetch.auth_decision(:proxy, %{}, "R1", %{"source" => "Server"}, @creds)

      assert {%{"response" => "ProvideCredentials"}, %{"R1" => 1}} =
               Fetch.auth_decision(:proxy, %{}, "R1", %{"source" => "Proxy"}, @creds)
    end

    test "the :server filter answers only Server challenges" do
      assert {%{"response" => "ProvideCredentials"}, %{"R1" => 1}} =
               Fetch.auth_decision(:server, %{}, "R1", %{"source" => "Server"}, @creds)

      assert {%{"response" => "Default"}, %{}} =
               Fetch.auth_decision(:server, %{}, "R1", %{"source" => "Proxy"}, @creds)
    end

    test "caps the attempts map so answered-but-unpruned challenges can't grow it unbounded" do
      # Only the rejection path deletes; a successful answer leaves its entry. At the
      # cap a fresh challenge resets the map rather than growing it without bound.
      full = Map.new(1..1024, &{"R#{&1}", 1})
      assert map_size(full) == 1024

      assert {%{"response" => "ProvideCredentials"}, %{"NEW" => 1}} =
               Fetch.auth_decision(:any, full, "NEW", %{"source" => "Server"}, @creds)
    end
  end

  describe "start_link/1" do
    test "arms asynchronously, then signals {:arm_failed, _, :noproc} on a dead connection" do
      # The handler is linked. init/1 now returns fast and defers arming to
      # handle_continue/2, so start_link succeeds; the dead-conn subscribe/enable then
      # fails there and is reported to the browser (here, the test process) as
      # {:arm_failed, pid, :noproc} before the handler stops quietly (:normal).
      Process.flag(:trap_exit, true)

      conn = spawn(fn -> :ok end)
      ref = Process.monitor(conn)
      assert_receive {:DOWN, ^ref, :process, ^conn, _}, 1_000

      assert {:ok, pid} =
               Fetch.start_link(conn: conn, browser: self(), username: "u", password: "p")

      assert_receive {:arm_failed, ^pid, :noproc}, 1_000
    end
  end

  describe "handle_continue(:arm) (FakeCDP)" do
    setup do
      {:ok, server} = FakeCDP.start()
      {:ok, conn} = Connection.start_link(server.url)
      assert_receive {:fake_cdp_connected, fake}, 2_000

      on_exit(fn ->
        try do
          # Closing the conn makes the (conn-monitoring) Fetch handler self-stop.
          if Process.alive?(conn), do: Connection.close(conn)
        catch
          :exit, _ -> :ok
        end
      end)

      %{conn: conn, fake: fake}
    end

    test "subscribes, enables Fetch with handleAuthRequests, then signals {:armed}", %{
      conn: conn,
      fake: fake
    } do
      {:ok, pid} = Fetch.start_link(conn: conn, browser: self(), username: "u", password: "p")

      assert_receive {:fake_cdp_recv, ^fake,
                      %{"id" => id, "method" => "Fetch.enable", "params" => params}},
                     2_000

      assert params["handleAuthRequests"] == true
      FakeCDP.send_text(fake, ~s({"id":#{id},"result":{}}))

      assert_receive {:armed, ^pid}, 2_000
    end
  end
end
