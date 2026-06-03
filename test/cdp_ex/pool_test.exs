defmodule CDPEx.PoolTest do
  use ExUnit.Case, async: true

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
