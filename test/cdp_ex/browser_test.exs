defmodule CDPEx.BrowserTest do
  use ExUnit.Case, async: true

  alias CDPEx.Browser
  alias CDPEx.Page

  describe "new_page/2 transport validation" do
    test "an unsupported :transport returns a structured error instead of crashing" do
      # The validation runs before any Chrome/connection I/O, so we can drive the
      # callback directly: a bad arg must yield a {:reply, ...} (the browser stays
      # up), not a raised CaseClauseError (which would take the GenServer — and
      # every page it owns — down).
      state = %Browser{}

      assert {:reply, {:error, {:invalid_transport, :bogus}}, ^state} =
               Browser.handle_call({:new_page, [transport: :bogus]}, {self(), make_ref()}, state)
    end
  end

  describe "session pruning" do
    test "a Target.detachedFromTarget event drops that session, keeping siblings" do
      # The Browser subscribes to this event on its browser_conn; the handler must
      # prune the ended session so long-lived browsers don't leak stale entries.
      conn = self()
      state = %Browser{browser_conn: conn, sessions: %{"T1" => "S1", "T2" => "S2"}}

      event =
        {:cdp_event, conn, "Target.detachedFromTarget", %{"sessionId" => "S1", "targetId" => "T1"},
         nil}

      assert {:noreply, %Browser{sessions: %{"T2" => "S2"}}} = Browser.handle_info(event, state)
    end
  end

  describe "browser connection teardown reason" do
    test "a clean ws-closed connection exit stops quietly (a :shutdown reason)" do
      # The Connection stops with {:shutdown, {:ws_closed, _}} when its socket drops
      # cleanly (e.g. Chrome going away). The Browser must propagate that as a
      # :shutdown reason so OTP logs no crash report for expected teardown.
      conn = self()
      state = %Browser{browser_conn: conn}
      reason = {:shutdown, {:ws_closed, :closed}}

      assert {:stop, {:shutdown, {:browser_connection_down, ^reason}}, ^state} =
               Browser.handle_info({:EXIT, conn, reason}, state)
    end

    test "an abnormal connection exit stays loud (a non-shutdown reason)" do
      conn = self()
      state = %Browser{browser_conn: conn}

      assert {:stop, {:browser_connection_down, :boom}, ^state} =
               Browser.handle_info({:EXIT, conn, :boom}, state)
    end
  end

  describe "close_page rejection paths" do
    test "rejects a dedicated handle this browser doesn't own" do
      # The reject branch does no I/O, so it's drivable directly; the match branch
      # (close_target + safe_close) is exercised by the integration suite.
      page = %Page{browser: self(), conn: self(), target_id: "T1"}
      state = %Browser{browser_conn: self(), pages: %{}}

      assert {:reply, {:error, :unknown_page}, ^state} =
               Browser.handle_call({:close_page, page}, {self(), make_ref()}, state)
    end

    test "rejects a second close of an already-pruned session page" do
      # After Target.detachedFromTarget prunes a session (or a prior close), closing
      # the stale handle again must be refused, not detach an unrelated target.
      page = %Page{browser: self(), conn: self(), target_id: "T1", session_id: "S1"}
      state = %Browser{browser_conn: self(), sessions: %{}}

      assert {:reply, {:error, :unknown_page}, ^state} =
               Browser.handle_call({:close_page, page}, {self(), make_ref()}, state)
    end
  end

  describe "child_spec" do
    test "sets a generous :shutdown so terminate/2 can reap Chrome" do
      assert %{shutdown: 10_000} = Browser.child_spec([])
    end
  end
end
