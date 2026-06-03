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

  describe "interception reservation (#30)" do
    test "rejects a :session page (shared-connection ownership problem)" do
      page = %Page{browser: self(), conn: self(), target_id: "T1", session_id: "S1"}
      state = %Browser{}

      assert {:reply, {:error, {:unsupported_transport, :session}}, ^state} =
               Browser.handle_call({:reserve_interception, page}, {self(), make_ref()}, state)
    end

    test "rejects a page this browser doesn't own" do
      page = %Page{browser: self(), conn: self(), target_id: "T1"}
      state = %Browser{pages: %{}}

      assert {:reply, {:error, :unknown_page}, ^state} =
               Browser.handle_call({:reserve_interception, page}, {self(), make_ref()}, state)
    end

    test "rejects when the page is already authenticated (mutual exclusion)" do
      conn = self()
      page = %Page{browser: self(), conn: conn, target_id: "T1"}
      state = %Browser{pages: %{"T1" => conn}, auths: %{"T1" => self()}}

      assert {:reply, {:error, {:conflict, :authenticated}}, ^state} =
               Browser.handle_call({:reserve_interception, page}, {self(), make_ref()}, state)
    end

    test "rejects a double reservation" do
      conn = self()
      page = %Page{browser: self(), conn: conn, target_id: "T1"}
      state = %Browser{pages: %{"T1" => conn}, intercepts: %{"T1" => {self(), make_ref()}}}

      assert {:reply, {:error, :already_intercepting}, ^state} =
               Browser.handle_call({:reserve_interception, page}, {self(), make_ref()}, state)
    end

    test "records and monitors the caller on success" do
      conn = self()
      page = %Page{browser: self(), conn: conn, target_id: "T1"}
      state = %Browser{pages: %{"T1" => conn}}
      caller = spawn(fn -> Process.sleep(:infinity) end)

      assert {:reply, :ok, new_state} =
               Browser.handle_call({:reserve_interception, page}, {caller, make_ref()}, state)

      assert {^caller, ref} = new_state.intercepts["T1"]
      assert is_reference(ref)

      Process.exit(caller, :kill)
    end

    test "release demonitors and drops the entry" do
      page = %Page{browser: self(), conn: self(), target_id: "T1"}
      ref = Process.monitor(self())
      state = %Browser{intercepts: %{"T1" => {self(), ref}}}

      assert {:reply, :ok, %Browser{intercepts: %{}}} =
               Browser.handle_call({:release_interception, page}, {self(), make_ref()}, state)
    end

    test "an owner :DOWN drops the entry and disables Fetch on its connection" do
      conn = self()
      ref = make_ref()
      state = %Browser{pages: %{"T1" => conn}, intercepts: %{"T1" => {self(), ref}}}

      assert {:noreply, %Browser{intercepts: %{}}, {:continue, {:disable_fetch, ^conn}}} =
               Browser.handle_info({:DOWN, ref, :process, self(), :killed}, state)
    end

    test "an owner :DOWN for an unknown ref is ignored" do
      state = %Browser{intercepts: %{}}

      assert {:noreply, ^state} =
               Browser.handle_info({:DOWN, make_ref(), :process, self(), :killed}, state)
    end

    test "authenticate is rejected when interception is active (reverse exclusion)" do
      conn = self()
      page = %Page{browser: self(), conn: conn, target_id: "T1"}
      state = %Browser{pages: %{"T1" => conn}, intercepts: %{"T1" => {self(), make_ref()}}}

      assert {:reply, {:error, {:conflict, :intercepting}}, ^state} =
               Browser.handle_call(
                 {:authenticate, page, [username: "u", password: "p"]},
                 {self(), make_ref()},
                 state
               )
    end
  end

  describe "non-blocking authenticate (#36)" do
    test "{:armed} replies :ok to the parked caller and clears pending_auth" do
      from = {self(), make_ref()}
      fetch = spawn(fn -> :ok end)
      state = %Browser{pending_auth: %{fetch => from}}

      assert {:noreply, %Browser{pending_auth: %{}}} = Browser.handle_info({:armed, fetch}, state)

      {_pid, tag} = from
      assert_receive {^tag, :ok}
    end

    test "{:arm_failed} fails the parked caller and clears its auths + pending_auth" do
      from = {self(), make_ref()}
      fetch = spawn(fn -> :ok end)
      state = %Browser{auths: %{"T1" => fetch}, pending_auth: %{fetch => from}}

      assert {:noreply, new_state} =
               Browser.handle_info(
                 {:arm_failed, fetch, {:cdp_error, "Fetch.enable", %{}}},
                 state
               )

      assert new_state.pending_auth == %{}
      assert new_state.auths == %{}

      {_pid, tag} = from
      assert_receive {^tag, {:error, {:cdp_error, "Fetch.enable", %{}}}}
    end

    test "a Fetch handler {:EXIT} during arming fails a still-parked caller (fallback)" do
      from = {self(), make_ref()}
      fetch = spawn(fn -> :ok end)
      state = %Browser{auths: %{"T1" => fetch}, pending_auth: %{fetch => from}}

      assert {:noreply, new_state} = Browser.handle_info({:EXIT, fetch, :boom}, state)

      assert new_state.pending_auth == %{}
      {_pid, tag} = from
      assert_receive {^tag, {:error, :boom}}
    end
  end
end
