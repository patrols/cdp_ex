defmodule CDPEx.ProcessLabelTest do
  use ExUnit.Case, async: true

  alias CDPEx.Connection
  alias CDPEx.FakeCDP
  alias CDPEx.Page
  alias CDPEx.Pool
  alias CDPEx.ProcessLabel

  # Reading a label back needs `:proc_lib.get_label/1` (OTP 27); setting one needs
  # `Process.set_label/1` (Elixir 1.17). cdp_ex supports 1.15/OTP 26, where
  # ProcessLabel.set/1 compiles to a no-op and there is nothing to assert — so the
  # whole module compiles away rather than asserting the no-op's emptiness.
  supported? =
    Code.ensure_loaded?(:proc_lib) and function_exported?(:proc_lib, :get_label, 1) and
      function_exported?(Process, :set_label, 1)

  if supported? do
    defp label_of(pid), do: :proc_lib.get_label(pid)

    describe "set/1" do
      test "attaches a label readable by the OTP process-label API" do
        pid =
          spawn(fn ->
            ProcessLabel.set({:cdp_test, 1})
            receive do: (:stop -> :ok)
          end)

        # Poll: set/1 runs concurrently with this assertion.
        assert eventually(fn -> label_of(pid) == {:cdp_test, 1} end)
        send(pid, :stop)
      end
    end

    describe "CDPEx.Connection" do
      test "is labelled with its DevTools target" do
        Process.flag(:trap_exit, true)
        {:ok, server} = FakeCDP.start()
        {:ok, conn} = Connection.start_link(server.url)
        assert_receive {:fake_cdp_connected, _fake}, 2_000

        assert label_of(conn) == {:cdp_connection, "/devtools/browser/fake"}

        Connection.close(conn)
      end

      test "is labelled before the WebSocket handshake completes" do
        # The reason the label is set at the top of init/1: a connection wedged in
        # recv_upgrade is precisely when an observer needs to know what the pid is,
        # and it has no state yet to identify itself by.
        Process.flag(:trap_exit, true)
        {:ok, server} = FakeCDP.start_stalling()

        # start_link/2 blocks in init/1 for a stalled handshake, so the pid never
        # comes back through the return value — reach it through the task's link
        # instead. (The fake's {:fake_cdp_stalled, _} carries its own pid, not ours.)
        task = Task.async(fn -> Connection.start_link(server.url, upgrade_timeout: 2_000) end)
        assert_receive {:fake_cdp_stalled, _fake}, 2_000

        conn = await_linked_conn(task.pid)
        assert label_of(conn) == {:cdp_connection, "/devtools/browser/fake"}

        # init/1 stops, and start_link propagates that down the link, so the task
        # exits rather than returning — wait it out so the stall never outlives the test.
        assert_receive {:EXIT, _pid, {:ws_upgrade, :upgrade_timeout}}, 3_000
        Task.shutdown(task, :brutal_kill)
      end
    end

    describe "CDPEx.Pool" do
      defmodule FakeBrowser do
        @moduledoc false
        use GenServer

        def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok)
        @impl true
        def init(:ok), do: {:ok, :ok}
      end

      test "labels the pool with its size" do
        Process.flag(:trap_exit, true)
        {:ok, pool} = Pool.start_link(size: 3, start_fun: &FakeBrowser.start_link/1)
        on_exit(fn -> stop_quietly(pool) end)

        assert label_of(pool) == {:cdp_pool, 3}
      end

      test "labels each browser-launch task with the pool it serves" do
        Process.flag(:trap_exit, true)
        test_pid = self()

        # The launch task is short-lived, so it reports its own label rather than
        # racing an external read.
        start_fun = fn opts ->
          send(test_pid, {:launch_label, label_of(self())})
          FakeBrowser.start_link(opts)
        end

        {:ok, pool} = Pool.start_link(size: 1, start_fun: start_fun)
        on_exit(fn -> stop_quietly(pool) end)

        {:ok, _browser} = Pool.checkout(pool)

        assert_receive {:launch_label, {:cdp_pool_launch, ^pool}}, 2_000
      end
    end

    describe "CDPEx.Page helpers" do
      test "labels the idle-wait helper with its role and target" do
        Process.flag(:trap_exit, true)
        test_pid = self()

        handler = "idle-label-#{System.unique_integer([:positive])}"

        # `:network_idle.watching` is emitted from inside the helper, so the handler
        # reads the label of the very process under test.
        :telemetry.attach(
          handler,
          [:cdp_ex, :network_idle, :watching],
          &__MODULE__.forward_helper_label/4,
          test_pid
        )

        on_exit(fn -> :telemetry.detach(handler) end)

        {:ok, server} = FakeCDP.start()
        {:ok, conn} = Connection.start_link(server.url)
        assert_receive {:fake_cdp_connected, fake}, 2_000
        on_exit(fn -> close_quietly(conn) end)

        page = %Page{browser: self(), conn: conn, target_id: "TARGET-1", session_id: nil}
        task = Task.async(fn -> Page.wait_for_network_idle(page, idle_time: 50, timeout: 2_000) end)

        assert_receive {:fake_cdp_recv, ^fake, %{"id" => id, "method" => "Network.enable"}}, 2_000
        FakeCDP.send_text(fake, ~s({"id":#{id},"result":{}}))

        assert_receive {:helper_label, {:cdp_page_helper, :idle_wait, "TARGET-1"}}, 2_000

        Task.await(task, 3_000)
      end
    end

    @doc false
    def forward_helper_label(_event, _measurements, _metadata, test_pid),
      do: send(test_pid, {:helper_label, :proc_lib.get_label(self())})

    # The connection a `Task.async(&Connection.start_link/2)` has linked to itself —
    # every other link on the task is the caller.
    defp await_linked_conn(task_pid, remaining \\ 500) do
      links = task_pid |> Process.info(:links) |> elem(1)

      case Enum.reject(links, &(&1 == self())) do
        [conn] ->
          conn

        [] when remaining > 0 ->
          Process.sleep(10)
          await_linked_conn(task_pid, remaining - 10)

        other ->
          flunk("expected exactly one linked connection, got: #{inspect(other)}")
      end
    end

    defp stop_quietly(pool) do
      if Process.alive?(pool), do: Pool.stop(pool)
    catch
      :exit, _ -> :ok
    end

    # The conn is linked to the test process, which ExUnit is already exiting when
    # on_exit runs — tolerate an in-flight teardown rather than failing on the race.
    defp close_quietly(conn) do
      if Process.alive?(conn), do: Connection.close(conn)
    catch
      :exit, _ -> :ok
    end

    defp eventually(fun, remaining \\ 500) do
      cond do
        fun.() ->
          true

        remaining <= 0 ->
          false

        true ->
          Process.sleep(10)
          eventually(fun, remaining - 10)
      end
    end
  end
end
