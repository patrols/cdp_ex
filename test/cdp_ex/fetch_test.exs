defmodule CDPEx.FetchTest do
  use ExUnit.Case, async: true

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
    test "stops with {:error, :noproc} when the connection is already dead" do
      # Trap exits: the handler is linked, and an init {:stop, :noproc} exits the
      # child with that (abnormal) reason.
      Process.flag(:trap_exit, true)

      conn = spawn(fn -> :ok end)
      ref = Process.monitor(conn)
      assert_receive {:DOWN, ^ref, :process, ^conn, _}, 1_000

      # A subscribe/enable against the dead conn would exit; init catches it so the
      # caller gets a clean error instead of a raw exit reason.
      assert {:error, :noproc} = Fetch.start_link(conn: conn, username: "u", password: "p")
    end
  end
end
