defmodule CDPEx.PoolTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias CDPEx.Pool

  # A stand-in for CDPEx.Browser: a trivial GenServer (so Pool's Browser.stop/1 —
  # a GenServer.stop — works) injected via the :start_fun option, letting us drive
  # the whole pool without launching Chrome.
  defmodule FakeBrowser do
    @moduledoc false
    use GenServer

    def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok)
    @impl true
    def init(:ok), do: {:ok, :ok}
  end

  setup do
    # The pool is start_linked to the test process; trap exits so a pool stop in
    # teardown can't take the test down.
    Process.flag(:trap_exit, true)
    :ok
  end

  test "checkout lazily launches up to size, then reuses warm browsers" do
    pool = start_pool(size: 2)

    {:ok, b1} = Pool.checkout(pool)
    {:ok, b2} = Pool.checkout(pool)
    assert b1 != b2
    assert :sys.get_state(pool).count == 2

    :ok = Pool.checkin(pool, b1)
    # Reuses the freed browser instead of launching a third.
    assert {:ok, ^b1} = Pool.checkout(pool)
    assert :sys.get_state(pool).count == 2
  end

  test "checkout blocks when the pool is exhausted and is served on checkin" do
    pool = start_pool(size: 1)
    {:ok, b1} = Pool.checkout(pool)

    task = Task.async(fn -> Pool.checkout(pool, 1_000) end)
    refute Task.yield(task, 100), "checkout should block while the pool is exhausted"

    :ok = Pool.checkin(pool, b1)
    assert {:ok, ^b1} = Task.await(task)
  end

  test "checkout times out when no browser frees up in time" do
    pool = start_pool(size: 1)
    {:ok, _b1} = Pool.checkout(pool)
    assert {:error, :timeout} = Pool.checkout(pool, 100)
  end

  test "with_browser returns the fun's value and checks the browser back in" do
    pool = start_pool(size: 1)
    assert :hello = Pool.with_browser(pool, fn _b -> :hello end)
    assert {:ok, _b} = Pool.checkout(pool, 500)
  end

  test "with_browser checks the browser back in even when the fun raises" do
    pool = start_pool(size: 1)
    assert_raise RuntimeError, fn -> Pool.with_browser(pool, fn _b -> raise "boom" end) end
    assert {:ok, _b} = Pool.checkout(pool, 500)
  end

  test "with_browser checks the browser back in even when the fun exits" do
    pool = start_pool(size: 1)
    # `after` runs on an exit too, so the browser is still returned.
    catch_exit(Pool.with_browser(pool, fn _b -> exit(:boom) end))
    assert {:ok, _b} = Pool.checkout(pool, 500)
  end

  test "a checkout owner that crashes has its browser reclaimed" do
    pool = start_pool(size: 1)
    parent = self()

    {owner, _ref} =
      spawn_monitor(fn ->
        {:ok, b} = Pool.checkout(pool)
        send(parent, {:checked_out, b})
        Process.sleep(:infinity)
      end)

    assert_receive {:checked_out, b1}, 1_000
    # Pool exhausted (size 1; the owner holds b1). Kill the owner.
    Process.exit(owner, :kill)
    # The pool reclaims b1 via the owner monitor, so it can be checked out again.
    assert {:ok, ^b1} = Pool.checkout(pool, 1_000)
  end

  test "a crashed browser is dropped and replaced on the next checkout" do
    pool = start_pool(size: 1)
    {:ok, b1} = Pool.checkout(pool)
    :ok = Pool.checkin(pool, b1)

    Process.exit(b1, :kill)
    assert eventually(fn -> :sys.get_state(pool).count == 0 end)

    assert {:ok, b2} = Pool.checkout(pool, 1_000)
    assert b2 != b1
  end

  test "stopping the pool replies to blocked waiters instead of crashing them" do
    pool = start_pool(size: 1)
    {:ok, _b1} = Pool.checkout(pool)

    task = Task.async(fn -> Pool.checkout(pool, 5_000) end)
    refute Task.yield(task, 100), "the second checkout should be blocked"

    Pool.stop(pool)
    assert {:error, :noproc} = Task.await(task)
  end

  test "child_spec derives its id from :id or :name so multiple pools can be supervised" do
    assert Pool.child_spec([]).id == Pool
    assert Pool.child_spec(name: :fast).id == :fast
    assert Pool.child_spec(id: :custom, name: :fast).id == :custom
  end

  test "a launch failure surfaces to the checkout caller" do
    pool = start_pool(size: 1, start_fun: fn _ -> {:error, :launch_boom} end)
    assert {:error, :launch_boom} = Pool.checkout(pool, 1_000)
    # The failed launch freed its slot, so a retry attempts a fresh launch (not stuck).
    assert {:error, :launch_boom} = Pool.checkout(pool, 1_000)
    assert Process.alive?(pool)
  end

  test "a launch task crash surfaces its reason as an error and the pool survives" do
    pool = start_pool(size: 1, start_fun: fn _ -> raise "launch crash" end)

    # The launch task crash logs a (expected) SASL report — capture it so it isn't noise.
    {result, _log} = with_log(fn -> Pool.checkout(pool, 1_000) end)

    # The task's :DOWN reason (the raised exception) is propagated, not a bare atom.
    assert {:error, {%RuntimeError{message: "launch crash"}, _stacktrace}} = result
    assert Process.alive?(pool)
  end

  test "the pool stays responsive while a launch is in flight (#22)" do
    # A launch that parks until the test releases it (deterministic, no wall-clock). In the
    # old synchronous pool the GenServer was blocked inside start_fun, so it couldn't process
    # any other message — the second checkout below would hang rather than time out.
    test = self()

    parked_start = fn opts ->
      send(test, {:launching, self()})
      receive do: (:proceed -> :ok)
      FakeBrowser.start_link(opts)
    end

    pool = start_pool(size: 1, start_fun: parked_start)

    slow = Task.async(fn -> Pool.checkout(pool, 5_000) end)
    assert_receive {:launching, launcher}, 1_000

    # The launch is provably still parked (we haven't sent :proceed), yet a second checkout
    # is served its :timeout — the pool is responsive. A synchronous pool would be stuck.
    assert {:error, :timeout} = Pool.checkout(pool, 50)

    # Release the launch; the original caller is served.
    send(launcher, :proceed)
    assert {:ok, _b} = Task.await(slow, 2_000)
  end

  test "launches browsers concurrently for simultaneous waiters (#22)" do
    # Each launch announces itself then parks. If launches were serial, only one would be in
    # flight at a time; we assert all three are parked at once, proving concurrency.
    test = self()

    parked_start = fn opts ->
      send(test, {:launching, self()})
      receive do: (:proceed -> :ok)
      FakeBrowser.start_link(opts)
    end

    pool = start_pool(size: 3, start_fun: parked_start)

    # Holders keep their browsers checked out (a Task that exits right after checkout would
    # let the pool reclaim its browser on the owner's death and re-hand it to the next
    # waiter — so we'd see fewer than three distinct browsers).
    holders =
      for _ <- 1..3 do
        spawn(fn ->
          {:ok, b} = Pool.checkout(pool, 3_000)
          send(test, {:got, b})
          receive do: (:release -> :ok), after: (5_000 -> :ok)
        end)
      end

    launchers =
      for _ <- 1..3 do
        assert_receive {:launching, pid}, 1_000
        pid
      end

    assert length(Enum.uniq(launchers)) == 3, "expected three concurrent launches"

    Enum.each(launchers, &send(&1, :proceed))

    browsers =
      for _ <- 1..3 do
        assert_receive {:got, b}, 2_000
        b
      end

    assert length(Enum.uniq(browsers)) == 3
    assert :sys.get_state(pool).count == 3

    Enum.each(holders, &send(&1, :release))
  end

  test "the pool stops with an attributable reason if its launch supervisor dies (#22)" do
    pool = start_pool(size: 1)
    ref = Process.monitor(pool)
    task_sup = :sys.get_state(pool).task_sup

    # The pool's stop logs an (expected) termination report — capture it so it isn't noise.
    capture_log(fn ->
      Process.exit(task_sup, :kill)

      # Rather than limping on unable to launch, the pool stops so its own supervisor can
      # restart it with a fresh task_sup.
      assert_receive {:DOWN, ^ref, :process, ^pool, {:task_sup_down, :killed}}, 1_000
    end)
  end

  test "a launch that outlives its timed-out waiter becomes a warm spare (#22)" do
    test = self()

    parked_start = fn opts ->
      send(test, {:launching, self()})
      receive do: (:proceed -> :ok)
      FakeBrowser.start_link(opts)
    end

    pool = start_pool(size: 1, start_fun: parked_start)

    # The waiter triggers a launch then times out before it resolves.
    assert {:error, :timeout} = Pool.checkout(pool, 50)
    assert_receive {:launching, launcher}, 1_000

    # The launch completes with no waiter left — its browser is kept as a warm spare, not
    # leaked, and a later checkout reuses it (count stays 1, no second launch).
    send(launcher, :proceed)
    assert {:ok, _b} = Pool.checkout(pool, 1_000)
    assert :sys.get_state(pool).count == 1
  end

  test "a launch that fails after its waiter timed out is handled without crashing (#22)" do
    test = self()

    parked_fail = fn _opts ->
      send(test, {:launching, self()})
      receive do: (:proceed -> :ok)
      {:error, :late_boom}
    end

    pool = start_pool(size: 1, start_fun: parked_fail)

    assert {:error, :timeout} = Pool.checkout(pool, 50)
    assert_receive {:launching, launcher}, 1_000

    # The failure arrives with no waiter to reply to; the pool absorbs it and frees the slot.
    send(launcher, :proceed)
    assert Process.alive?(pool)
    # The slot freed, so a fresh checkout can launch again (it parks, so we time it out).
    assert {:error, :timeout} = Pool.checkout(pool, 50)
  end

  defp start_pool(opts) do
    {:ok, pool} =
      opts |> Keyword.put_new(:start_fun, &FakeBrowser.start_link/1) |> Pool.start_link()

    on_exit(fn -> stop_quietly(pool) end)
    pool
  end

  defp stop_quietly(pool) do
    if Process.alive?(pool), do: Pool.stop(pool)
  catch
    :exit, _ -> :ok
  end

  defp eventually(fun, retries \\ 100) do
    cond do
      fun.() ->
        true

      retries == 0 ->
        false

      true ->
        Process.sleep(10)
        eventually(fun, retries - 1)
    end
  end
end
