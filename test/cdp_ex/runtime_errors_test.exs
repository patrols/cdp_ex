defmodule CDPEx.RuntimeErrorsTest.Stub do
  @moduledoc false
  # Stands in for a Browser or Pool on the far side of a GenServer.call. `mode`:
  #   :crash  — dies (not :normal, not :shutdown) on any call, before replying
  #   :hold   — never replies; tells `notify` who called, and whether that caller
  #             later goes down (the Browser's #40 cleanup hook for authenticate)
  use GenServer

  def start(mode, notify \\ nil), do: GenServer.start(__MODULE__, {mode, notify})

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(_request, _from, {:crash, _} = state), do: {:stop, :boom, state}

  def handle_call(request, {caller, _tag}, {:hold, notify} = state) do
    Process.monitor(caller)
    send(notify, {:stub_called, request, caller})
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, {:hold, notify} = state) do
    send(notify, {:stub_caller_down, pid})
    {:noreply, state}
  end
end

defmodule CDPEx.RuntimeErrorsTest do
  # Runtime failures come back as {:error, _} (or :ok for an idempotent stop), never as
  # a raise or an exit in the caller. Each test here fails with the conversion removed.
  use ExUnit.Case, async: true

  alias CDPEx.Chrome
  alias CDPEx.Connection
  alias CDPEx.FakeCDP
  alias CDPEx.Page
  alias CDPEx.Pool
  alias CDPEx.RuntimeErrorsTest.Stub

  @moduletag :tmp_dir
  @root? System.cmd("id", ["-u"]) == {"0\n", 0}

  defp dead_pid do
    pid = spawn(fn -> :ok end)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, _, _, _}
    pid
  end

  # Runs `fun` in a process that does NOT trap exits, so a linked start failure
  # would kill it before it could report.
  defp in_untrapped_process(fun) do
    parent = self()
    tag = make_ref()
    {pid, mon} = spawn_monitor(fn -> send(parent, {tag, fun.()}) end)

    receive do
      {^tag, result} ->
        assert_receive {:DOWN, ^mon, :process, ^pid, :normal}
        result

      {:DOWN, ^mon, :process, ^pid, reason} ->
        flunk("caller exited instead of getting a return value: #{inspect(reason)}")
    end
  end

  defp executable(dir) do
    path = Path.join(dir, "chrome")
    File.write!(path, "#!/bin/sh\nsleep 30\n")
    File.chmod!(path, 0o755)
    path
  end

  defp page(conn, browser), do: %Page{browser: browser, conn: conn, target_id: "T"}

  describe "Chrome.launch/1" do
    test "a profile dir that can't be created is {:launch_failed, {:user_data_dir, posix}}",
         %{tmp_dir: tmp} do
      file = Path.join(tmp, "a_file")
      File.write!(file, "")

      assert Chrome.launch(chrome_binary: executable(tmp), user_data_dir: Path.join(file, "p")) ==
               {:error, {:launch_failed, {:user_data_dir, :enotdir}}}
    end

    @tag skip: @root? && "root ignores the owner execute bit"
    test "a spawn the OS refuses is {:launch_failed, {:spawn, posix}}", %{tmp_dir: tmp} do
      # Execute bit for "other" only: executable?/1 lets it through, but the owner
      # can't run it, so Port.open raises :eacces.
      path = Path.join(tmp, "not_mine")
      File.write!(path, "#!/bin/sh\n")
      File.chmod!(path, 0o601)

      assert Chrome.launch(chrome_binary: path, user_data_dir: Path.join(tmp, "profile")) ==
               {:error, {:launch_failed, {:spawn, :eacces}}}
    end
  end

  describe "starting without trapping exits" do
    test "CDPEx.launch/1 returns a launch error to an untrapped caller" do
      assert in_untrapped_process(fn -> CDPEx.launch(chrome_binary: "/no/such/chrome") end) ==
               {:error, {:chrome_not_found, "/no/such/chrome"}}
    end

    test "CDPEx.connect/2 returns a connect error to an untrapped caller" do
      assert {:error, {:ws_connect, _}} =
               in_untrapped_process(fn -> CDPEx.connect("ws://127.0.0.1:1/devtools/browser/x") end)
    end

    test "Connection.start_link/2 returns a connect error to an untrapped caller" do
      assert {:error, {:ws_connect, _}} =
               in_untrapped_process(fn ->
                 Connection.start_link("ws://127.0.0.1:1/devtools/browser/x")
               end)
    end
  end

  describe "Browser requests" do
    test "new_page/2 and close_page/2 on a dead browser are {:error, :noproc}" do
      dead = dead_pid()
      assert CDPEx.new_page(dead) == {:error, :noproc}
      assert CDPEx.close_page(dead, page(self(), self())) == {:error, :noproc}
    end

    @tag capture_log: true
    test "new_page/2 on a browser that dies before replying is {:error, :noproc}" do
      {:ok, browser} = Stub.start(:crash)
      assert CDPEx.new_page(browser) == {:error, :noproc}
    end

    test "stop/1 on a browser that is already gone is :ok" do
      assert CDPEx.stop(dead_pid()) == :ok
    end

    test "with_page/3 on a dead browser is {:error, :noproc} and never runs fun" do
      assert CDPEx.with_page(dead_pid(), fn _ -> flunk("fun ran") end) == {:error, :noproc}
    end

    test "Page.authenticate/4 on a dead browser is {:error, :noproc}" do
      assert Page.authenticate(page(self(), dead_pid()), "u", "p") == {:error, :noproc}
    end

    test "Page.authenticate/4 whose caller dies mid-call lets the browser see it go (#40)" do
      {:ok, browser} = Stub.start(:hold, self())
      page = page(self(), browser)
      caller = spawn(fn -> Page.authenticate(page, "u", "p") end)

      assert_receive {:stub_called, {:authenticate, ^page, _opts}, relay}
      Process.exit(caller, :kill)
      assert_receive {:stub_caller_down, ^relay}, 1_000
    end

    test "Page.authenticate/4 leaves no {:EXIT} behind for a caller that traps exits" do
      Process.flag(:trap_exit, true)
      assert Page.authenticate(page(self(), dead_pid()), "u", "p") == {:error, :noproc}
      refute_receive {:EXIT, _, _}, 100
    end
  end

  describe "Connection" do
    setup do
      Process.flag(:trap_exit, true)
      {:ok, server} = FakeCDP.start()
      {:ok, conn} = Connection.start_link(server.url)
      assert_receive {:fake_cdp_connected, fake}, 2_000
      %{conn: conn, fake: fake}
    end

    test "params JSON can't encode are {:invalid_args, _} and the connection survives",
         %{conn: conn, fake: fake} do
      assert {:error, {:invalid_args, %Jason.EncodeError{}}} =
               Connection.call(conn, "Emulation.setUserAgentOverride", %{"userAgent" => <<0xFF>>})

      assert {:error, {:invalid_args, %Protocol.UndefinedError{}}} =
               Connection.call(conn, "Runtime.evaluate", %{"x" => self()})

      assert Process.alive?(conn)

      # Neither was sent nor used an id: the next call is the first frame, with id 1.
      call = Task.async(fn -> Connection.call(conn, "Page.enable", %{}, 5_000) end)
      assert_receive {:fake_cdp_recv, ^fake, frame}, 2_000
      assert %{"method" => "Page.enable", "id" => 1} = frame
      FakeCDP.send_text(fake, ~s({"id":1,"result":{}}))
      assert Task.await(call) == {:ok, %{}}
    end

    test "arguments of the wrong type raise in the caller, not in the connection",
         %{conn: conn} do
      # apply/3 so the compiler's type checker doesn't reject the deliberately bad call.
      for args <- [["Page.enable", [bad: 1]], [:"Page.enable", %{}]] do
        assert_raise FunctionClauseError, fn -> apply(Connection, :call, [conn | args]) end
      end

      assert Process.alive?(conn)
    end

    test "call/5 and await_event/4 on a connection killed mid-call are {:error, :noproc}",
         %{conn: conn} do
      call = Task.async(fn -> Connection.call(conn, "Page.enable", %{}, 5_000) end)
      assert_receive {:fake_cdp_recv, _fake, %{"method" => "Page.enable"}}, 2_000
      wait = Task.async(fn -> Connection.await_event(conn, fn _ -> false end, 5_000) end)
      wait_until_waiting(conn)

      Process.exit(conn, :kill)

      assert Task.await(call) == {:error, :noproc}
      assert Task.await(wait) == {:error, :noproc}
    end

    test "subscribe/4 that can't register in time is {:timeout, :subscribe}", %{conn: conn} do
      :ok = :sys.suspend(conn)

      assert Connection.subscribe(conn, "Page.lifecycleEvent", 100) ==
               {:error, {:timeout, :subscribe}}

      :ok = :sys.resume(conn)
    end

    test "subscribe/unsubscribe/close on a gone connection: :noproc, :ok, :ok", %{conn: conn} do
      :ok = Connection.close(conn)
      assert Connection.subscribe(conn, "Page.lifecycleEvent") == {:error, :noproc}
      assert Connection.unsubscribe(conn, "Page.lifecycleEvent") == :ok
      assert Connection.close(conn) == :ok
    end

    defp wait_until_waiting(conn) do
      if :sys.get_state(conn).waiters == [] do
        Process.sleep(10)
        wait_until_waiting(conn)
      end
    end
  end

  describe "Pool" do
    setup do
      Process.flag(:trap_exit, true)
      :ok
    end

    test "checkout/2 on a pool that crashes mid-wait is {:error, :noproc}" do
      {:ok, pool} =
        Pool.start_link(size: 1, start_fun: fn _ -> Agent.start_link(fn -> :ok end) end)

      {:ok, _held} = Pool.checkout(pool)
      waiter = Task.async(fn -> Pool.checkout(pool, :infinity) end)
      wait_for_waiter(pool)

      Process.exit(pool, :kill)
      assert Task.await(waiter) == {:error, :noproc}
    end

    @tag capture_log: true
    test "with_page/3 on a pooled browser that dies under new_page is {:error, :noproc}" do
      {:ok, pool} = Pool.start_link(size: 1, start_fun: fn _ -> Stub.start(:crash) end)
      assert Pool.with_page(pool, fn _ -> flunk("fun ran") end) == {:error, :noproc}
    end

    test "stop/1 on a pool that is already gone is :ok" do
      {:ok, pool} = Pool.start_link(size: 1)
      :ok = Pool.stop(pool)
      assert Pool.stop(pool) == :ok
    end

    defp wait_for_waiter(pool) do
      if :queue.is_empty(:sys.get_state(pool).waiting) do
        Process.sleep(10)
        wait_for_waiter(pool)
      end
    end
  end
end

defmodule CDPEx.RuntimeErrorsTest.UncleanStop do
  @moduledoc false
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias CDPEx.Browser

  test "stop helpers stay quiet for a gone or clean stop and warn for anything else" do
    for reason <- [:noproc, :normal, :shutdown, {:shutdown, :closed}] do
      assert capture_log(fn -> assert Browser.warn_unclean_stop("X", reason) == :ok end) ==
               ""
    end

    log =
      capture_log(fn ->
        assert Browser.warn_unclean_stop("X", {%RuntimeError{}, []}) == :ok
      end)

    assert log =~ "[X] stopped with"
  end
end

defmodule CDPEx.RuntimeErrorsTest.CloseTimeout do
  # A separate module so this 15s wait runs alongside the authenticate one.
  @moduledoc false
  use ExUnit.Case, async: true

  alias CDPEx.Page
  alias CDPEx.RuntimeErrorsTest.Stub

  @moduletag timeout: 30_000

  test "close_page/2 on a browser that can't answer in 15s is {:timeout, :close_page}" do
    {:ok, browser} = Stub.start(:hold, self())

    assert CDPEx.close_page(browser, %Page{browser: browser, conn: self(), target_id: "T"}) ==
             {:error, {:timeout, :close_page}}
  end
end

defmodule CDPEx.RuntimeErrorsTest.AuthenticateTimeout do
  @moduledoc false
  use ExUnit.Case, async: true

  alias CDPEx.Page
  alias CDPEx.RuntimeErrorsTest.Stub

  @moduletag timeout: 30_000

  test "authenticate/4 that times out returns {:timeout, :authenticate} and the browser sees its caller go" do
    {:ok, browser} = Stub.start(:hold, self())
    page = %Page{browser: browser, conn: self(), target_id: "T"}

    assert Page.authenticate(page, "u", "p") == {:error, {:timeout, :authenticate}}

    # The Browser tears down a still-arming handler when the process that called it
    # goes down (#40); returning the timeout must not take that signal away.
    assert_receive {:stub_called, {:authenticate, ^page, _opts}, caller}
    assert caller != self()
    assert_receive {:stub_caller_down, ^caller}, 1_000
  end
end

defmodule CDPEx.RuntimeErrorsTest.OwnedProfileDir do
  # Not async: the profile dir cdp_ex creates itself goes under System.tmp_dir/0, which
  # these tests point at a scratch dir through the process-global TMPDIR.
  @moduledoc false
  use ExUnit.Case, async: false

  alias CDPEx.Chrome

  @moduletag :tmp_dir
  @root? System.cmd("id", ["-u"]) == {"0\n", 0}

  setup %{tmp_dir: tmp} do
    scratch = Path.join(tmp, "scratch")
    File.mkdir_p!(scratch)
    previous = System.get_env("TMPDIR")
    System.put_env("TMPDIR", scratch)

    on_exit(fn ->
      if previous, do: System.put_env("TMPDIR", previous), else: System.delete_env("TMPDIR")
    end)

    %{scratch: scratch}
  end

  @tag skip: @root? && "root ignores the owner execute bit"
  test "a spawn the OS refuses removes the profile dir cdp_ex created",
       %{tmp_dir: tmp, scratch: scratch} do
    path = Path.join(tmp, "not_mine")
    File.write!(path, "#!/bin/sh\n")
    File.chmod!(path, 0o601)

    assert Chrome.launch(chrome_binary: path) == {:error, {:launch_failed, {:spawn, :eacces}}}
    assert File.ls!(scratch) == []
  end

  test ":extra_args Port.open rejects raise ArgumentError and remove the profile dir",
       %{tmp_dir: tmp, scratch: scratch} do
    path = Path.join(tmp, "chrome")
    File.write!(path, "#!/bin/sh\nsleep 30\n")
    File.chmod!(path, 0o755)

    assert_raise ArgumentError, fn -> Chrome.launch(chrome_binary: path, extra_args: [123]) end
    assert File.ls!(scratch) == []
  end
end
