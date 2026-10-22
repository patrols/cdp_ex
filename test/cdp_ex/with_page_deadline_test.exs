defmodule CDPEx.WithPageDeadlineTest.StubBrowser do
  @moduledoc false
  # Stand-in for CDPEx.Browser: a page's "connection" never answers until close_page
  # stops it, so a blocked call fails as a real one does when its page goes away.
  use GenServer

  alias CDPEx.Page

  def start(opts \\ []), do: GenServer.start(__MODULE__, Keyword.put_new(opts, :notify, self()))
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts), do: {:ok, %{opts: opts, open: %{}, next: 1}}

  @impl true
  def handle_call({:new_page, _opts}, _from, state) do
    Process.sleep(Keyword.get(state.opts, :new_page_delay, 0))
    reply_page(state, state.opts[:new_page_error])
  end

  def handle_call({:close_page, %Page{target_id: tid}}, {from, _tag}, state) do
    Process.sleep(Keyword.get(state.opts, :close_page_delay, 0))

    case Map.pop(state.open, tid) do
      {nil, _} ->
        {:reply, {:error, :unknown_page}, state}

      {conn, open} ->
        send(conn, :close)
        if notify = state.opts[:notify], do: send(notify, {:page_closed, tid, from})
        {:reply, :ok, %{state | open: open}}
    end
  end

  defp reply_page(state, nil) do
    conn = spawn(&silent_conn/0)
    tid = "T#{state.next}"
    page = %Page{browser: self(), conn: conn, target_id: tid}
    {:reply, {:ok, page}, %{state | open: Map.put(state.open, tid, conn), next: state.next + 1}}
  end

  defp reply_page(state, reason), do: {:reply, {:error, reason}, state}

  defp silent_conn do
    receive do
      :close -> :ok
      {:"$gen_call", _from, _request} -> silent_conn()
    end
  end
end

defmodule CDPEx.WithPageDeadlineTest do
  use ExUnit.Case, async: true

  alias CDPEx.FakeCDP
  alias CDPEx.FixtureServer
  alias CDPEx.Page
  alias CDPEx.Pool
  alias CDPEx.WithPageDeadlineTest.StubBrowser

  setup do
    # ExUnit's runner monitors the test process; the watchdog is the one monitor added.
    Process.put(:baseline_monitored_by, monitored_by())
    {:ok, browser} = StubBrowser.start()
    on_exit(fn -> if Process.alive?(browser), do: GenServer.stop(browser) end)
    %{browser: browser}
  end

  describe "a fired deadline" do
    test "returns :deadline_exceeded once the page is torn down under a blocked call", %{
      browser: browser
    } do
      {elapsed_us, result} =
        :timer.tc(fn ->
          CDPEx.with_page(
            browser,
            fn page ->
              stash_watchdog()
              Page.evaluate(page, "1 + 1", timeout: 30_000)
            end,
            deadline: 100
          )
        end)

      assert result == {:error, :deadline_exceeded}
      assert elapsed_us >= 100_000
      assert elapsed_us < 2_000_000
      assert_received {:page_closed, "T1", closer}
      refute closer == self(), "expected the watchdog, not the caller's cleanup, to close it"
      assert_clean()
    end

    test "converts a raise the teardown caused", %{browser: browser} do
      result =
        CDPEx.with_page(
          browser,
          fn page ->
            stash_watchdog()
            {:ok, _} = Page.evaluate(page, "1 + 1", timeout: 30_000)
          end,
          deadline: 50
        )

      assert result == {:error, :deadline_exceeded}
      assert_clean()
    end

    test "catches a fun that sleeps past it at its next browser call", %{browser: browser} do
      result =
        CDPEx.with_page(
          browser,
          fn page ->
            stash_watchdog()
            Process.sleep(200)
            Page.evaluate(page, "1 + 1")
          end,
          deadline: 50
        )

      assert result == {:error, :deadline_exceeded}
      assert_clean()
    end

    test "wins over a value fun returned after the teardown", %{browser: browser} do
      result =
        CDPEx.with_page(
          browser,
          fn _page ->
            stash_watchdog()
            Process.sleep(150)
            :finished
          end,
          deadline: 50
        )

      assert result == {:error, :deadline_exceeded}
      assert_clean()
    end

    test "sends the caller nothing while fun runs, even after the teardown" do
      {:ok, browser} = StubBrowser.start(notify: nil)

      result =
        CDPEx.with_page(
          browser,
          fn page ->
            stash_watchdog()
            _ = Page.evaluate(page, "1 + 1", timeout: 30_000)

            receive do
              msg -> Process.put(:swallowed, msg)
            after
              100 -> :ok
            end
          end,
          deadline: 50
        )

      assert result == {:error, :deadline_exceeded}
      assert Process.get(:swallowed) == nil
      assert_clean()
      GenServer.stop(browser)
    end

    test "during new_page skips fun and still closes the page" do
      {:ok, browser} = StubBrowser.start(new_page_delay: 200)

      result =
        CDPEx.with_page(browser, fn _page -> Process.put(:ran, true) end, deadline: 50)

      assert result == {:error, :deadline_exceeded}
      assert Process.get(:ran) == nil
      assert_receive {:page_closed, "T1", _closer}, 1_000
      assert Process.info(self(), :monitors) == {:monitors, []}
      assert Process.info(self(), :messages) == {:messages, []}
      GenServer.stop(browser)
    end

    test "passes a new_page error that arrives after it through as itself" do
      {:ok, browser} = StubBrowser.start(new_page_delay: 200, new_page_error: :boom)

      assert CDPEx.with_page(browser, fn _ -> :ran end, deadline: 50) == {:error, :boom}

      assert Process.info(self(), :monitors) == {:monitors, []}
      assert Process.info(self(), :messages) == {:messages, []}
      GenServer.stop(browser)
    end

    test "passes through Pool.with_page/3 and leaves the pooled browser usable" do
      Process.flag(:trap_exit, true)

      {:ok, pool} =
        Pool.start_link(size: 1, start_fun: fn _ -> StubBrowser.start_link(notify: nil) end)

      on_exit(fn ->
        try do
          Pool.stop(pool)
        catch
          :exit, _ -> :ok
        end
      end)

      blocked = &Page.evaluate(&1, "1", timeout: 30_000)
      assert Pool.with_page(pool, blocked, deadline: 50) == {:error, :deadline_exceeded}

      {browser, tid} = Pool.with_page(pool, &{&1.browser, &1.target_id}, deadline: 5_000)
      assert tid == "T2"
      assert Process.alive?(browser)
      assert :sys.get_state(browser).open == %{}
      assert :sys.get_state(pool).count == 1
    end

    test "is decided by the clock, not by when the watchdog gets to run", %{browser: browser} do
      # Starve the watchdog past the deadline and have it resume only after the caller's
      # cancel is already in its mailbox: the late `fun` must still be exceeded.
      fun = fn _page ->
        stash_watchdog()
        watchdog = Process.get(:watchdog)
        caller = self()

        # Only the suspending process may resume, so one helper does both.
        spawn(fn ->
          true = :erlang.suspend_process(watchdog)
          send(caller, :suspended)
          Process.sleep(300)
          :erlang.resume_process(watchdog)
        end)

        assert_receive :suspended
        Process.sleep(150)
        :late
      end

      assert CDPEx.with_page(browser, fun, deadline: 50) == {:error, :deadline_exceeded}
      assert_clean()
    end

    test "a new_page error before the deadline passes through" do
      {:ok, browser} = StubBrowser.start(new_page_error: :boom)
      assert CDPEx.with_page(browser, fn _ -> :ran end, deadline: 5_000) == {:error, :boom}
      GenServer.stop(browser)
    end

    test "leaves a caller-owned browser running", %{browser: browser} do
      assert {:error, :deadline_exceeded} =
               CDPEx.with_page(browser, &Page.evaluate(&1, "1", timeout: 30_000), deadline: 50)

      assert Process.alive?(browser)
      assert_received {:page_closed, "T1", _}
      assert CDPEx.with_page(browser, fn page -> page.target_id end, deadline: 1_000) == "T2"
    end

    test "emits [:cdp_ex, :with_page, :deadline_exceeded] with what fun did", %{
      browser: browser
    } do
      attach_deadline_handler()

      CDPEx.with_page(browser, &Page.evaluate(&1, "1", timeout: 30_000), deadline: 50)

      assert_received {:telemetry, %{system_time: _}, %{deadline: 50, outcome: {:error, :noproc}}}

      CDPEx.with_page(browser, &({:ok, _} = Page.evaluate(&1, "1", timeout: 30_000)), deadline: 50)
      assert_received {:telemetry, _, %{outcome: {:raised, :error, %MatchError{}}}}

      CDPEx.with_page(browser, fn _ -> Process.sleep(100) && :late end, deadline: 50)
      assert_received {:telemetry, _, %{outcome: :value}}

      {:ok, slow} = StubBrowser.start(new_page_delay: 200, notify: nil)
      CDPEx.with_page(slow, fn _ -> :ran end, deadline: 50)
      assert_received {:telemetry, _, %{outcome: :not_started}}
      GenServer.stop(slow)
    end
  end

  describe "a deadline that does not fire" do
    test "is not fired by slow cleanup after fun returned" do
      {:ok, browser} = StubBrowser.start(close_page_delay: 300)

      fun = fn _page ->
        stash_watchdog()
        {:ok, :value}
      end

      assert CDPEx.with_page(browser, fun, deadline: 100) == {:ok, :value}
      assert_received {:page_closed, "T1", closer}
      assert closer == self(), "the watchdog must be gone before the caller's cleanup"
      assert_clean()
      GenServer.stop(browser)
    end

    test "returns fun's value and leaves no watchdog, monitor or message", %{browser: browser} do
      fun = fn _page ->
        stash_watchdog()
        :ok
      end

      assert CDPEx.with_page(browser, fun, deadline: 5_000) == :ok

      assert_received {:page_closed, "T1", closer}
      assert closer == self()
      assert_clean()
    end

    test "propagates a raise unchanged", %{browser: browser} do
      assert_raise RuntimeError, "boom", fn ->
        fun = fn _page ->
          stash_watchdog()
          raise "boom"
        end

        CDPEx.with_page(browser, fun, deadline: 5_000)
      end

      assert_clean()
    end

    test "propagates exits and throws unchanged", %{browser: browser} do
      assert catch_exit(CDPEx.with_page(browser, fn _ -> exit(:bye) end, deadline: 5_000)) ==
               :bye

      assert catch_throw(CDPEx.with_page(browser, fn _ -> throw(:ball) end, deadline: 5_000)) ==
               :ball
    end

    test "returns new_page's {:error, :noproc} for a dead browser" do
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, _, _, _}

      assert CDPEx.with_page(dead, fn _ -> :ok end, deadline: 5_000) == {:error, :noproc}
      assert Process.info(self(), :monitors) == {:monitors, []}
    end
  end

  describe "without a deadline" do
    test "starts no watchdog and propagates a raise", %{browser: browser} do
      assert CDPEx.with_page(browser, fn _ -> Process.info(self(), :monitors) end) ==
               {:monitors, []}

      assert_raise RuntimeError, "boom", fn ->
        CDPEx.with_page(browser, fn _ -> raise "boom" end)
      end
    end
  end

  test "when the caller dies the watchdog closes its page and exits", %{browser: browser} do
    test_pid = self()

    caller =
      spawn(fn ->
        baseline = monitored_by()

        CDPEx.with_page(
          browser,
          fn _page ->
            Process.put(:baseline_monitored_by, baseline)
            stash_watchdog()
            send(test_pid, {:watchdog, Process.get(:watchdog)})
            Process.sleep(:infinity)
          end,
          deadline: 60_000
        )
      end)

    assert_receive {:watchdog, watchdog}, 1_000
    ref = Process.monitor(watchdog)
    Process.exit(caller, :kill)
    assert_receive {:page_closed, "T1", ^watchdog}, 1_000
    assert_receive {:DOWN, ^ref, :process, ^watchdog, _}, 1_000
  end

  test "a :deadline among the launch options raises instead of being ignored" do
    assert_raise ArgumentError, ~r/third argument/, fn ->
      CDPEx.with_page([deadline: 5_000], fn _ -> :ran end)
    end
  end

  test "an invalid :deadline raises ArgumentError", %{browser: browser} do
    for bad <- [0, -1, 4_294_967_296, 1.5, :soon, "100"] do
      assert_raise ArgumentError, ~r/invalid :deadline/, fn ->
        CDPEx.with_page(browser, fn _ -> :ok end, deadline: bad)
      end
    end
  end

  describe "a throwaway browser near the deadline" do
    setup do
      test_pid = self()
      responder = spawn_link(fn -> fake_chrome(test_pid) end)
      {:ok, server} = FakeCDP.start(responder)

      handler = "start-hook-#{System.unique_integer([:positive])}"
      :telemetry.attach(handler, [:cdp_ex, :connect, :stop], &__MODULE__.start_hook/4, nil)
      on_exit(fn -> :telemetry.detach(handler) end)
      %{url: server.url}
    end

    test "a start that completes after it skips new_page", %{url: url} do
      result =
        run_unlinked(fn ->
          Process.put(:start_hook, {:sleep, 80})
          CDPEx.with_page([connect: url], fn _ -> :ran end, deadline: 50)
        end)

      assert result == {:error, :deadline_exceeded}
      refute_received {:fake_cdp, "Target.createTarget"}
    end

    test "passing during new_page waits for it instead of stopping the browser under it",
         %{url: url} do
      for _ <- 1..5 do
        result =
          run_unlinked(fn ->
            # The browser is held busy past the deadline, so the watchdog's teardown
            # would reach it before the caller's new_page.
            Process.put(:start_hook, {:suspend, 150})
            CDPEx.with_page([connect: url], fn _ -> :ran end, deadline: 50)
          end)

        assert result == {:error, :deadline_exceeded}
      end
    end
  end

  describe "launch" do
    @describetag :tmp_dir

    test "a launch the deadline cut short returns :deadline_exceeded", %{tmp_dir: tmp_dir} do
      Process.flag(:trap_exit, true)
      stub = never_ready_chrome!(tmp_dir)
      attach_deadline_handler()

      {elapsed_us, result} =
        :timer.tc(fn ->
          CDPEx.with_page([chrome_binary: stub], fn _ -> :ran end, deadline: 1_000)
        end)

      assert result == {:error, :deadline_exceeded}
      assert elapsed_us < 5_000_000
      assert_received {:telemetry, _, %{deadline: 1_000, launch_error: {:debug_url_not_found, ex}}}
      assert ex =~ "never ready"
    end

    test "a malformed DevToolsActivePort at the capped timeout is the deadline's too", %{
      tmp_dir: tmp_dir
    } do
      Process.flag(:trap_exit, true)
      attach_deadline_handler()

      stub =
        write_stub!(tmp_dir, "malformed-port-chrome", """
        #!/bin/sh
        for arg in "$@"; do
          case "$arg" in
            --user-data-dir=*) echo 'half-written' > "${arg#--user-data-dir=}/DevToolsActivePort" ;;
          esac
        done
        exec sleep 30
        """)

      # Generous: the stub must have written the file by the final read, under load.
      assert CDPEx.with_page([chrome_binary: stub], fn _ -> :ran end, deadline: 1_500) ==
               {:error, :deadline_exceeded}

      assert_received {:telemetry, _, %{launch_error: {:devtools_file_malformed, _}}}
    end

    test "connect: nil launches, so the launch timeout is capped", %{tmp_dir: tmp_dir} do
      Process.flag(:trap_exit, true)
      stub = never_ready_chrome!(tmp_dir)

      {elapsed_us, result} =
        :timer.tc(fn ->
          CDPEx.with_page([connect: nil, chrome_binary: stub], fn _ -> :ran end, deadline: 300)
        end)

      assert result == {:error, :deadline_exceeded}
      # Uncapped, the default 15s launch timeout would run out instead.
      assert elapsed_us < 5_000_000
    end

    test "a deadline equal to launch_timeout is still attributed to the deadline", %{
      tmp_dir: tmp_dir
    } do
      Process.flag(:trap_exit, true)
      stub = never_ready_chrome!(tmp_dir)
      opts = [chrome_binary: stub, launch_timeout: 300]

      assert CDPEx.with_page(opts, fn _ -> :ran end, deadline: 300) ==
               {:error, :deadline_exceeded}
    end

    test "a failed launch returns an error to a caller that doesn't trap exits", %{
      tmp_dir: tmp_dir
    } do
      stub = never_ready_chrome!(tmp_dir)
      missing = Path.join(tmp_dir, "no-such-chrome")

      cases = [
        {[chrome_binary: missing], [], {:error, {:chrome_not_found, missing}}},
        {[chrome_binary: missing], [deadline: 5_000], {:error, {:chrome_not_found, missing}}},
        {[chrome_binary: stub, launch_timeout: 300], [], :debug_url_not_found},
        {[chrome_binary: stub], [deadline: 300], {:error, :deadline_exceeded}}
      ]

      for {launch_opts, opts, expected} <- cases do
        {pid, ref} =
          spawn_monitor(fn ->
            result = CDPEx.with_page(launch_opts, fn _ -> :ran end, opts)
            exit({:done, result, Process.info(self(), [:trap_exit, :messages])})
          end)

        assert_receive {:DOWN, ^ref, :process, ^pid, {:done, result, info}}, 10_000
        assert info == [trap_exit: false, messages: []]

        case expected do
          :debug_url_not_found -> assert {:error, {:debug_url_not_found, _}} = result
          _ -> assert result == expected
        end
      end
    end

    test "a connect: start that fails after the deadline is exceeded, before it is not" do
      attach_deadline_handler()
      {:ok, %{url: base}} = FixtureServer.start(json_version: :hang)
      launch_opts = [connect: base, discovery_timeout: 300]

      # The 5s default discovery timeout is capped at the deadline too.
      {elapsed_us, result} =
        :timer.tc(fn -> CDPEx.with_page([connect: base], fn _ -> :ran end, deadline: 100) end)

      assert result == {:error, :deadline_exceeded}
      assert elapsed_us < 2_000_000
      assert_received {:telemetry, _, %{launch_error: {:connect_discovery_failed, _}}}

      assert CDPEx.with_page(launch_opts, fn _ -> :ran end, deadline: 200) ==
               {:error, :deadline_exceeded}

      assert_received {:telemetry, _,
                       %{
                         outcome: :not_started,
                         launch_error: {:connect_discovery_failed, :discovery_timeout}
                       }}

      assert CDPEx.with_page(launch_opts, fn _ -> :ran end, deadline: 5_000) ==
               {:error, {:connect_discovery_failed, :discovery_timeout}}
    end

    test "a nil or :infinity :discovery_timeout is capped at the deadline too" do
      {:ok, %{url: base}} = FixtureServer.start(json_version: :hang)

      for discovery_timeout <- [nil, :infinity] do
        launch_opts = [connect: base, discovery_timeout: discovery_timeout]

        {elapsed_us, result} =
          :timer.tc(fn -> CDPEx.with_page(launch_opts, fn _ -> :ran end, deadline: 100) end)

        assert result == {:error, :deadline_exceeded}
        assert elapsed_us < 2_000_000
      end
    end

    test "an invalid :discovery_timeout raises instead of being capped" do
      {:ok, %{url: base}} = FixtureServer.start(json_version: :hang)

      for timeout <- ["5000", 4_294_967_296] do
        assert_raise ArgumentError, ~r/invalid :discovery_timeout #{inspect(timeout)}/, fn ->
          CDPEx.with_page([connect: base, discovery_timeout: timeout], fn _ -> :ran end,
            deadline: 100
          )
        end
      end
    end

    test "a start failure the cap didn't cause comes back as itself, even past it" do
      # A DevTools endpoint that rejects the WebSocket upgrade, after the deadline.
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)

      spawn_link(fn ->
        {:ok, sock} = :gen_tcp.accept(listen)
        Process.sleep(300)
        :gen_tcp.send(sock, "HTTP/1.1 403 Forbidden\r\ncontent-length: 0\r\n\r\n")
        Process.sleep(:infinity)
      end)

      endpoint = "ws://127.0.0.1:#{port}/devtools/browser/x"

      {elapsed_us, result} =
        :timer.tc(fn -> CDPEx.with_page([connect: endpoint], fn _ -> :ran end, deadline: 100) end)

      assert elapsed_us >= 300_000, "the failure must arrive after the deadline"
      assert {:error, reason} = result
      refute reason == :deadline_exceeded
    end

    test "a launch_timeout below the deadline keeps its own error", %{tmp_dir: tmp_dir} do
      Process.flag(:trap_exit, true)
      stub = never_ready_chrome!(tmp_dir)

      assert {:error, {:debug_url_not_found, _}} =
               CDPEx.with_page([chrome_binary: stub, launch_timeout: 300], fn _ -> :ran end,
                 deadline: 10_000
               )
    end
  end

  # Runs in the with_page caller once connect returns.
  @doc false
  def start_hook(_event, _measurements, _metadata, _config) do
    case Process.get(:start_hook) do
      {:sleep, ms} ->
        Process.sleep(ms)

      {:suspend, ms} ->
        {:links, [browser]} = Process.info(self(), :links)
        :ok = :sys.suspend(browser)
        spawn(fn -> Process.sleep(ms) && :sys.resume(browser) end)

      nil ->
        :ok
    end
  end

  # Runs `fun` in a caller that doesn't trap exits; returns its result after checking
  # the caller survived with a clean mailbox.
  defp run_unlinked(fun) do
    {pid, ref} =
      spawn_monitor(fn ->
        result = fun.()
        exit({:done, result, Process.info(self(), [:trap_exit, :messages])})
      end)

    assert_receive {:DOWN, ^ref, :process, ^pid, {:done, result, info}}, 10_000
    assert info == [trap_exit: false, messages: []]
    result
  end

  # Answers a connected browser's session new_page and teardown.
  defp fake_chrome(test_pid) do
    receive do
      {:fake_cdp_recv, fake, %{"id" => id, "method" => method} = frame} ->
        send(test_pid, {:fake_cdp, method})

        result =
          case method do
            "Target.createTarget" -> ~s({"targetId":"T1"})
            "Target.attachToTarget" -> ~s({"sessionId":"S1"})
            _ -> "{}"
          end

        session = if sid = frame["sessionId"], do: ~s(,"sessionId":"#{sid}"), else: ""
        FakeCDP.send_text(fake, ~s({"id":#{id},"result":#{result}#{session}}))

      _other ->
        :ok
    end

    fake_chrome(test_pid)
  end

  defp attach_deadline_handler do
    handler = "deadline-test-#{System.unique_integer([:positive])}"
    event = [:cdp_ex, :with_page, :deadline_exceeded]
    :telemetry.attach(handler, event, &__MODULE__.forward/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)
  end

  # Forwards only events emitted by the attaching test: the event fires in the
  # with_page caller, and other async tests here fire it too.
  @doc false
  def forward(_event, measurements, metadata, test_pid) do
    if self() == test_pid, do: send(test_pid, {:telemetry, measurements, metadata})
  end

  defp monitored_by do
    {:monitored_by, pids} = Process.info(self(), :monitored_by)
    pids
  end

  # The watchdog sets up its monitor of us asynchronously after it is spawned.
  defp stash_watchdog(retries \\ 100) do
    case monitored_by() -- Process.get(:baseline_monitored_by) do
      [watchdog] ->
        Process.put(:watchdog, watchdog)
        :ok

      [] when retries > 0 ->
        Process.sleep(1)
        stash_watchdog(retries - 1)
    end
  end

  defp assert_clean do
    receive do
      {:page_closed, _tid, _closer} -> :ok
    after
      0 -> :ok
    end

    watchdog = Process.get(:watchdog)
    refute watchdog && Process.alive?(watchdog)
    assert monitored_by() == Process.get(:baseline_monitored_by)
    assert Process.info(self(), :monitors) == {:monitors, []}
    assert Process.info(self(), :messages) == {:messages, []}
  end

  # exec, so the shell flushes the stderr line before sleeping.
  defp never_ready_chrome!(dir) do
    write_stub!(dir, "never-ready-chrome", """
    #!/bin/sh
    echo 'stub-chrome: never ready' 1>&2
    exec sleep 30
    """)
  end

  defp write_stub!(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, body)
    File.chmod!(path, 0o755)
    path
  end
end
