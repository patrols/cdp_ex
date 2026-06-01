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
end
