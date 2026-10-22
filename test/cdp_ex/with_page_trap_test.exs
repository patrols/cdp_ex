defmodule CDPEx.WithPageTrapTest do
  # with_page/3 traps exits in the caller around a throwaway browser; these check the
  # trap is invisible once it returns. `connect:` takes the same path as a launch, so a
  # FakeCDP stands in for Chrome (the real-Chrome versions are in integration_test.exs).
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias CDPEx.FakeCDP

  setup do
    responder = spawn_link(&fake_chrome/0)
    {:ok, server} = FakeCDP.start(responder)
    %{launch_opts: [connect: server.url]}
  end

  describe "a foreign exit signal during the call" do
    test "terminates a non-trapping caller with its reason", %{launch_opts: launch_opts} do
      {pid, ref} =
        spawn_monitor(fn ->
          {:ok, _} = :timer.exit_after(50, :job_timeout)
          CDPEx.with_page(launch_opts, fn _ -> Process.sleep(300) end)
          exit(:survived)
        end)

      assert_receive {:DOWN, ^ref, :process, ^pid, :job_timeout}, 5_000
    end

    test "terminates the caller with its reason when fun raises", %{launch_opts: launch_opts} do
      {pid, ref} =
        spawn_monitor(fn ->
          {:ok, _} = :timer.exit_after(50, :job_timeout)

          CDPEx.with_page(launch_opts, fn _ ->
            Process.sleep(300)
            raise "boom"
          end)
        end)

      assert_receive {:DOWN, ^ref, :process, ^pid, :job_timeout}, 5_000
    end

    test "terminates the caller when a linked process crashes", %{launch_opts: launch_opts} do
      {pid, ref} =
        spawn_monitor(fn ->
          spawn_link(fn ->
            Process.sleep(50)
            exit(:linked_crash)
          end)

          CDPEx.with_page(launch_opts, fn _ -> Process.sleep(300) end)
          exit(:survived)
        end)

      assert_receive {:DOWN, ^ref, :process, ^pid, :linked_crash}, 5_000
    end

    test "stays a message for a caller that traps exits", %{launch_opts: launch_opts} do
      {pid, ref} =
        spawn_monitor(fn ->
          Process.flag(:trap_exit, true)
          {:ok, _} = :timer.exit_after(50, :job_timeout)
          result = CDPEx.with_page(launch_opts, fn _ -> Process.sleep(300) && :ran end)
          exit({:done, result, Process.info(self(), [:trap_exit, :messages])})
        end)

      assert_receive {:DOWN, ^ref, :process, ^pid, {:done, :ran, info}}, 5_000
      assert [trap_exit: true, messages: [{:EXIT, _timer, :job_timeout}]] = info
    end

    test "is dropped when :normal", %{launch_opts: launch_opts} do
      {pid, ref} =
        spawn_monitor(fn ->
          caller = self()

          spawn(fn ->
            Process.sleep(50)
            Process.exit(caller, :normal)
          end)

          result = CDPEx.with_page(launch_opts, fn _ -> Process.sleep(300) && :ran end)
          exit({:done, result, Process.info(self(), [:trap_exit, :messages])})
        end)

      assert_receive {:DOWN, ^ref, :process, ^pid, {:done, :ran, info}}, 5_000
      assert info == [trap_exit: false, messages: []]
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

      assert_receive {:DOWN, ^ref, :process, ^pid, {:done, :ran, info}}, 5_000
      assert info == [trap_exit: false, messages: []]
    end)
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
