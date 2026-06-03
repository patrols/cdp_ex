defmodule CDPEx.ChromeTest do
  # async: false — these touch process env vars and (in the integration case)
  # launch a real OS process.
  use ExUnit.Case, async: false

  alias CDPEx.Chrome

  describe "resolve_binary/1" do
    setup do
      # Snapshot and clear the env vars so each test controls them explicitly.
      saved = {System.get_env("CDP_EX_CHROME_BINARY"), System.get_env("CHROME_BINARY")}
      System.delete_env("CDP_EX_CHROME_BINARY")
      System.delete_env("CHROME_BINARY")

      on_exit(fn ->
        {a, b} = saved

        if a,
          do: System.put_env("CDP_EX_CHROME_BINARY", a),
          else: System.delete_env("CDP_EX_CHROME_BINARY")

        if b, do: System.put_env("CHROME_BINARY", b), else: System.delete_env("CHROME_BINARY")
      end)
    end

    test "the :chrome_binary option wins over everything" do
      System.put_env("CDP_EX_CHROME_BINARY", "/from/env")
      assert Chrome.resolve_binary(chrome_binary: "/explicit/chrome") == "/explicit/chrome"
    end

    test "CDP_EX_CHROME_BINARY wins over CHROME_BINARY" do
      System.put_env("CDP_EX_CHROME_BINARY", "/cdp/ex/chrome")
      System.put_env("CHROME_BINARY", "/generic/chrome")
      assert Chrome.resolve_binary([]) == "/cdp/ex/chrome"
    end

    test "falls back to CHROME_BINARY" do
      System.put_env("CHROME_BINARY", "/generic/chrome")
      assert Chrome.resolve_binary([]) == "/generic/chrome"
    end

    test "falls back to an OS default when nothing is set" do
      # We don't assert the exact path (OS-dependent) — just that it's a non-empty
      # absolute path, not nil.
      path = Chrome.resolve_binary([])
      assert is_binary(path) and path != ""
    end
  end

  describe "default_args/2" do
    test "includes --headless by default" do
      assert "--headless" in Chrome.default_args("/tmp/p")
    end

    test "omits --headless when headless: false" do
      refute "--headless" in Chrome.default_args("/tmp/p", headless: false)
    end

    test "wires the profile dir and remote debugging port" do
      args = Chrome.default_args("/tmp/profile")
      assert "--user-data-dir=/tmp/profile" in args
      assert "--remote-debugging-port=0" in args
    end

    test "applies a custom window size" do
      assert "--window-size=800,600" in Chrome.default_args("/tmp/p", window_size: {800, 600})
    end

    test "ends with the about:blank initial target" do
      assert List.last(Chrome.default_args("/tmp/p")) == "about:blank"
    end

    test "ships no anti-bot defaults" do
      args = Chrome.default_args("/tmp/p")
      refute Enum.any?(args, &String.contains?(&1, "AutomationControlled"))
      refute "--disable-web-security" in args
      refute Enum.any?(args, &String.starts_with?(&1, "--user-agent"))
    end
  end

  describe "build_args/2" do
    test "appends :extra_args to the defaults" do
      args = Chrome.build_args("/tmp/p", extra_args: ["--proxy-server=http://x:1"])
      assert "--proxy-server=http://x:1" in args
      assert "--headless" in args
    end

    test ":args fully replaces the defaults" do
      args = Chrome.build_args("/tmp/p", args: ["--only", "--these"])
      assert args == ["--only", "--these"]
      refute "--headless" in args
    end
  end

  describe "launch/1" do
    test "returns chrome_not_found for a missing binary" do
      assert {:error, {:chrome_not_found, "/no/such/chrome"}} =
               Chrome.launch(chrome_binary: "/no/such/chrome")
    end

    test "returns chrome_not_found for a directory" do
      dir = System.tmp_dir!()
      assert {:error, {:chrome_not_found, ^dir}} = Chrome.launch(chrome_binary: dir)
    end

    @tag :tmp_dir
    test "returns chrome_not_found for a non-executable file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "not-chrome")
      File.write!(path, "#!/bin/sh\n")
      File.chmod!(path, 0o644)

      assert {:error, {:chrome_not_found, ^path}} = Chrome.launch(chrome_binary: path)
    end

    @tag :tmp_dir
    test "times out to {:debug_url_not_found, stderr} when the endpoint never appears", %{
      tmp_dir: tmp_dir
    } do
      # A stand-in binary that prints to stderr and stays alive without ever
      # exposing a DevTools endpoint (no ws:// line, no DevToolsActivePort file).
      stub =
        write_stub!(tmp_dir, "stub-no-endpoint", """
        #!/bin/sh
        # exec, so the shell flushes the buffered stderr line to the pipe before
        # sleeping (a plain `sleep` would hold it unflushed past the timeout).
        echo 'stub-chrome: no devtools endpoint here' 1>&2
        exec sleep 30
        """)

      # A generous timeout: this path always waits it out (no endpoint ever
      # appears), and the captured stderr must arrive before the deadline even
      # under concurrent test load — a tight window races the port data delivery.
      assert {:error, {:debug_url_not_found, excerpt}} =
               Chrome.launch(chrome_binary: stub, launch_timeout: 2_000)

      # The captured stderr is threaded into the error, so the failure is
      # self-diagnosing rather than a context-free atom.
      assert excerpt =~ "no devtools endpoint"
    end

    @tag :tmp_dir
    test "returns as soon as DevToolsActivePort is readable, without the stderr line", %{
      tmp_dir: tmp_dir
    } do
      # Writes a valid DevToolsActivePort into its --user-data-dir but never prints
      # the "DevTools listening on ws://" line — the case that used to block for the
      # full timeout. The poll must pick the file up and return promptly.
      stub =
        write_stub!(tmp_dir, "stub-writes-port", """
        #!/bin/sh
        dir=""
        for arg in "$@"; do
          case "$arg" in
            --user-data-dir=*) dir="${arg#--user-data-dir=}" ;;
          esac
        done
        {
          echo '9222'
          echo '/devtools/browser/stub-uuid'
        } > "$dir/DevToolsActivePort"
        echo 'stub-chrome: started without a listening line' 1>&2
        sleep 30
        """)

      {elapsed_us, result} =
        :timer.tc(fn -> Chrome.launch(chrome_binary: stub, launch_timeout: 5_000) end)

      assert {:ok, handle} = result
      assert handle.debug_url == "ws://127.0.0.1:9222/devtools/browser/stub-uuid"
      # Returned on a poll tick, far under the 5s ceiling — not by waiting it out.
      assert elapsed_us < 2_000_000

      :ok = Chrome.stop(handle)
      refute File.dir?(handle.user_data_dir)
    end

    @tag :tmp_dir
    test "returns {:devtools_file_malformed, excerpt} for an unparseable DevToolsActivePort", %{
      tmp_dir: tmp_dir
    } do
      # Writes a DevToolsActivePort that exists but doesn't parse (no port/path
      # lines) — the terminal reason carries the contents excerpt, not a bare atom.
      stub =
        write_stub!(tmp_dir, "stub-malformed-port", """
        #!/bin/sh
        dir=""
        for arg in "$@"; do
          case "$arg" in
            --user-data-dir=*) dir="${arg#--user-data-dir=}" ;;
          esac
        done
        echo 'not-a-valid-devtools-port-file' > "$dir/DevToolsActivePort"
        echo 'stub-chrome: wrote a malformed port file' 1>&2
        sleep 30
        """)

      assert {:error, {:devtools_file_malformed, excerpt}} =
               Chrome.launch(chrome_binary: stub, launch_timeout: 2_000)

      assert excerpt =~ "not-a-valid-devtools-port-file"
    end

    @tag :integration
    test "launches real Chrome, exposes a browser ws URL, and cleans up on stop" do
      assert {:ok, handle} = Chrome.launch([])
      assert handle.debug_url =~ ~r{^ws://[^/]+/devtools/browser/}
      assert is_integer(handle.os_pid)
      assert File.dir?(handle.user_data_dir)

      :ok = Chrome.stop(handle)

      # Temp profile dir we created is gone after stop.
      refute File.dir?(handle.user_data_dir)
    end
  end

  # Write an executable stand-in "chrome" script into a tmp dir for launch/1 tests
  # that exercise the readiness path without a real browser.
  defp write_stub!(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, body)
    File.chmod!(path, 0o755)
    path
  end
end
