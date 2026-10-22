defmodule CDPEx.WithPageTrapTest do
  # with_page/3 traps exits in the caller around a throwaway browser; these check the
  # trap is invisible once it returns. `connect:` takes the same path as a launch, so a
  # FakeCDP stands in for Chrome (the real-Chrome versions are in integration_test.exs).
  #
  # No test races a timer against fun: a foreign exit is sent while fun is parked on a
  # message, and the release is sent after it by the same process, so signal ordering
  # between a pair of processes puts the EXIT in the caller's mailbox first.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias CDPEx.FakeCDP

  setup do
    responder = spawn_link(&fake_chrome/0)
    {:ok, server} = FakeCDP.start(responder)
    %{launch_opts: [connect: server.url]}
  end

  describe "a foreign exit signal during the call" do
    test "from :timer.exit_after/2 terminates a non-trapping caller with its reason", %{
      launch_opts: launch_opts
    } do
      {pid, ref} =
        spawn_monitor(fn ->
          CDPEx.with_page(launch_opts, fn _ ->
            {:ok, _} = :timer.exit_after(50, :job_timeout)
            await_queued_exit(:job_timeout)
          end)

          exit(:survived)
        end)

      assert_receive {:DOWN, ^ref, :process, ^pid, :job_timeout}, 10_000
    end

    for opts <- [[], [deadline: 30_000]] do
      test "terminates a non-trapping caller with its reason (opts: #{inspect(opts)})", %{
        launch_opts: launch_opts
      } do
        caller = spawn_caller(fn -> CDPEx.with_page(launch_opts, &park/1, unquote(opts)) end)
        assert_down_with_foreign_exit(caller, :job_timeout)
      end
    end

    test "terminates the caller with its reason when fun raises", %{launch_opts: launch_opts} do
      caller =
        spawn_caller(fn ->
          CDPEx.with_page(launch_opts, fn page ->
            park(page)
            raise "boom"
          end)
        end)

      assert_down_with_foreign_exit(caller, :job_timeout)
    end

    test "terminates the caller once a :deadline is exceeded", %{launch_opts: launch_opts} do
      caller =
        spawn_caller(fn ->
          CDPEx.with_page(
            launch_opts,
            fn page ->
              browser_ref = Process.monitor(page.browser)
              park(page)
              # The watchdog stops the browser at the deadline, so the call is exceeded.
              # Wide enough that a slow start still leaves fun started in time.
              receive do: ({:DOWN, ^browser_ref, _, _, _} -> :late)
            end,
            deadline: 1_500
          )
        end)

      assert_down_with_foreign_exit(caller, :job_timeout)
    end

    test "terminates the caller when a linked process crashes", %{launch_opts: launch_opts} do
      {pid, ref} =
        spawn_monitor(fn ->
          linked = spawn_link(fn -> receive do: (:crash -> exit(:linked_crash)) end)

          CDPEx.with_page(launch_opts, fn _ ->
            linked_ref = Process.monitor(linked)
            send(linked, :crash)
            # Same sender, so its EXIT is queued before this DOWN.
            receive do: ({:DOWN, ^linked_ref, _, _, _} -> :ok)
          end)

          exit(:survived)
        end)

      assert_receive {:DOWN, ^ref, :process, ^pid, :linked_crash}, 10_000
    end

    test "stays a message for a caller that traps exits", %{launch_opts: launch_opts} do
      {pid, ref} =
        spawn_caller(fn ->
          Process.flag(:trap_exit, true)
          CDPEx.with_page(launch_opts, &park/1)
        end)

      test_pid = self()
      foreign_exit(pid, :job_timeout)
      assert_receive {:DOWN, ^ref, :process, ^pid, {:done, :ran, info}}, 10_000
      assert [trap_exit: true, messages: [{:EXIT, ^test_pid, :job_timeout}]] = info
    end

    test "is dropped when :normal", %{launch_opts: launch_opts} do
      {pid, ref} = spawn_caller(fn -> CDPEx.with_page(launch_opts, &park/1) end)
      foreign_exit(pid, :normal)
      assert_receive {:DOWN, ^ref, :process, ^pid, {:done, :ran, info}}, 10_000
      assert info == [trap_exit: false, messages: []]
    end
  end

  # on_start_error: the start fails after the foreign exit is already queued.
  describe "a foreign exit signal during a failed start" do
    for opts <- [[], [deadline: 30_000]] do
      test "still terminates a non-trapping caller (opts: #{inspect(opts)})" do
        {:ok, server} = FakeCDP.start_stalling()

        {pid, ref} =
          spawn_monitor(fn ->
            CDPEx.with_page([connect: server.url], fn _ -> :ran end, unquote(opts))
            exit(:survived)
          end)

        # The upgrade request is in, so the caller is blocked in the start, trapping.
        assert_receive {:fake_cdp_stalled, fake}, 10_000
        Process.exit(pid, :job_timeout)
        await_queued(pid, {:EXIT, self(), :job_timeout})
        FakeCDP.hard_close(fake)

        assert_receive {:DOWN, ^ref, :process, ^pid, :job_timeout}, 10_000
      end
    end
  end

  # drain_exit/1 takes one queued browser EXIT with `after 0`; the extra one injected
  # here stands for a browser EXIT that wasn't queued yet when it ran.
  describe "a browser EXIT still queued when the trap is restored" do
    test "is dropped, not re-delivered", %{launch_opts: launch_opts} do
      {pid, ref} =
        spawn_monitor(fn ->
          result =
            CDPEx.with_page(launch_opts, fn page ->
              send(self(), {:EXIT, page.browser, :browser_crash})
              send(self(), {:EXIT, page.browser, :browser_crash})
              :ran
            end)

          exit({:done, result, Process.info(self(), [:trap_exit, :messages])})
        end)

      assert_receive {:DOWN, ^ref, :process, ^pid, {:done, :ran, info}}, 10_000
      assert info == [trap_exit: false, messages: []]
    end

    test "doesn't mask a foreign exit queued after it", %{launch_opts: launch_opts} do
      caller =
        spawn_caller(fn ->
          CDPEx.with_page(launch_opts, fn page ->
            send(self(), {:EXIT, page.browser, :browser_crash})
            send(self(), {:EXIT, page.browser, :browser_crash})
            park(page)
          end)
        end)

      assert_down_with_foreign_exit(caller, :job_timeout)
    end
  end

  test "a browser that dies under the call doesn't reach a non-trapping caller", %{
    launch_opts: launch_opts
  } do
    # The killed Browser's Connection logs its crash.
    capture_log(fn ->
      {pid, ref} =
        spawn_monitor(fn ->
          result =
            CDPEx.with_page(launch_opts, fn page ->
              browser_ref = Process.monitor(page.browser)
              Process.exit(page.browser, :kill)
              receive do: ({:DOWN, ^browser_ref, _, _, _} -> :ok)
              :ran
            end)

          exit({:done, result, Process.info(self(), [:trap_exit, :messages])})
        end)

      assert_receive {:DOWN, ^ref, :process, ^pid, {:done, :ran, info}}, 10_000
      assert info == [trap_exit: false, messages: []]
    end)
  end

  # Runs `call` in a monitored caller that exits {:done, result, info} if it survives.
  defp spawn_caller(call) do
    test_pid = self()

    spawn_monitor(fn ->
      Process.put(:trap_test_pid, test_pid)
      result = call.()
      exit({:done, result, Process.info(self(), [:trap_exit, :messages])})
    end)
  end

  # Inside fun: tell the test, then wait for its go-ahead.
  defp park(_page) do
    send(Process.get(:trap_test_pid), {:parked, self()})
    receive do: (:go -> :ran)
  end

  defp foreign_exit(pid, reason) do
    assert_receive {:parked, ^pid}, 10_000
    Process.exit(pid, reason)
    send(pid, :go)
  end

  defp assert_down_with_foreign_exit({pid, ref}, reason) do
    foreign_exit(pid, reason)
    assert_receive {:DOWN, ^ref, :process, ^pid, ^reason}, 10_000
  end

  defp await_queued_exit(reason) do
    {:messages, messages} = Process.info(self(), :messages)

    if Enum.any?(messages, &match?({:EXIT, _, ^reason}, &1)) do
      :ok
    else
      Process.sleep(5)
      await_queued_exit(reason)
    end
  end

  defp await_queued(pid, message) do
    {:messages, messages} = Process.info(pid, :messages)

    if message not in messages do
      Process.sleep(5)
      await_queued(pid, message)
    end
  end

  # Answers a connected browser's session new_page and teardown.
  defp fake_chrome do
    receive do
      {:fake_cdp_recv, fake, %{"id" => id, "method" => method} = frame} ->
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

    fake_chrome()
  end
end
