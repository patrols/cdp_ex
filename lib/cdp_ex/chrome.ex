defmodule CDPEx.Chrome do
  @moduledoc """
  Launches, discovers, and stops the headless Chrome OS process.

  `launch/1` opens Chrome via a `Port` with `--remote-debugging-port=0`, reads
  the chosen DevTools WebSocket URL from Chrome's stderr (falling back to the
  `DevToolsActivePort` file), and returns a handle. `stop/1` kills the process
  and removes the temp profile.

  The argument and discovery helpers (`build_args/2`, `default_args/2`,
  `resolve_binary/1`) are pure and unit-testable without launching anything.

  ## Launch options

    * `:headless` — run headless (default `true`); `false` drops `--headless`
    * `:chrome_binary` — path to the Chrome/Chromium executable
    * `:window_size` — `{width, height}` (default `{1280, 1024}`)
    * `:user_data_dir` — profile dir; a fresh temp dir is created (and removed on
      stop) when omitted. A caller-supplied dir is left in place.
    * `:extra_args` — extra flags appended to the defaults
    * `:args` — full flag list that **replaces** the defaults entirely
    * `:launch_timeout` — ms to wait for the DevTools URL (default `15_000`)

  ## Default flags

  Defaults are deliberately neutral (stability + headless), not scraping-tuned.
  Anti-bot flags (spoofed user-agent, `--disable-web-security`,
  `--disable-blink-features=AutomationControlled`, …) are **not** included — add
  them via `:extra_args` if you need them.

  > #### Sandbox {: .warning}
  >
  > The defaults include `--no-sandbox` / `--disable-setuid-sandbox` so Chrome
  > starts in the common container/CI setup (running as root), where the sandbox
  > can't initialize. That is a security reduction when visiting untrusted pages —
  > to keep the sandbox, run as a non-root user and override the flag list via
  > `:args` (omitting the two sandbox flags).
  """

  import Bitwise, only: [band: 2]

  @launch_timeout 15_000
  @stop_exit_timeout 3_000
  @default_window_size {1280, 1024}

  @type handle :: %{
          port: port(),
          os_pid: non_neg_integer() | nil,
          debug_url: String.t(),
          user_data_dir: String.t(),
          owns_data_dir: boolean()
        }

  @doc """
  Launches headless Chrome and returns `{:ok, handle}` once its DevTools
  endpoint is reachable, or `{:error, reason}`.

  The `Port` is owned by the calling process, which therefore receives the
  `{port, {:exit_status, _}}` message if Chrome dies.
  """
  @spec launch(keyword()) :: {:ok, handle()} | {:error, term()}
  def launch(opts \\ []) do
    binary = resolve_binary(opts)

    if executable?(binary) do
      do_launch(binary, opts)
    else
      {:error, {:chrome_not_found, binary}}
    end
  end

  defp do_launch(binary, opts) do
    {user_data_dir, owns?} = resolve_user_data_dir(opts)
    File.mkdir_p!(user_data_dir)
    args = build_args(user_data_dir, opts)
    timeout = Keyword.get(opts, :launch_timeout, @launch_timeout)

    port =
      Port.open({:spawn_executable, binary}, [:binary, :stderr_to_stdout, :exit_status, args: args])

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    case await_debug_url(port, user_data_dir, "", deadline(timeout)) do
      {:ok, debug_url} ->
        {:ok,
         %{
           port: port,
           os_pid: os_pid,
           debug_url: debug_url,
           user_data_dir: user_data_dir,
           owns_data_dir: owns?
         }}

      {:error, reason} ->
        kill(os_pid)
        close_port(port)
        _ = if owns?, do: File.rm_rf(user_data_dir)
        {:error, reason}
    end
  end

  @doc """
  Stops Chrome: kills the OS process, closes the port, and removes the temp
  profile dir (only when `cdp_ex` created it). Idempotent and crash-safe — it is
  the cleanup run from `CDPEx.Browser`'s `terminate/2` callback.
  """
  @spec stop(handle()) :: :ok
  def stop(%{os_pid: os_pid, port: port} = handle) do
    kill(os_pid)
    close_port(port)
    # `kill -9` is asynchronous: it returns before the OS has reaped Chrome, and
    # a still-alive Chrome (or a child) can recreate files in the profile dir
    # right after we delete it — which is exactly how the temp dir "reappeared"
    # and failed cleanup on Linux CI. Wait for the process to actually exit, then
    # remove the dir, retrying until it's gone (covers a child's final flush).
    await_exit(os_pid, deadline(@stop_exit_timeout))
    if Map.get(handle, :owns_data_dir, false), do: remove_dir(handle.user_data_dir)
    :ok
  end

  @doc """
  Resolves the Chrome binary path from (in order) the `:chrome_binary` option,
  the `CDP_EX_CHROME_BINARY` env var, the `CHROME_BINARY` env var, then an
  OS-specific default.
  """
  @spec resolve_binary(keyword()) :: String.t()
  def resolve_binary(opts) do
    opts[:chrome_binary] ||
      System.get_env("CDP_EX_CHROME_BINARY") ||
      System.get_env("CHROME_BINARY") ||
      default_binary()
  end

  @doc """
  Builds the full Chrome argument list for a profile dir.

  Returns `opts[:args]` verbatim when given (full override); otherwise the
  neutral defaults plus `opts[:extra_args]`.
  """
  @spec build_args(String.t(), keyword()) :: [String.t()]
  def build_args(user_data_dir, opts \\ []) do
    case Keyword.get(opts, :args) do
      nil -> default_args(user_data_dir, opts) ++ Keyword.get(opts, :extra_args, [])
      args when is_list(args) -> args
    end
  end

  @doc """
  The neutral default flag list (stability + headless), with `--user-data-dir`,
  `--window-size`, and the conditional `--headless` applied from `opts`.
  """
  @spec default_args(String.t(), keyword()) :: [String.t()]
  def default_args(user_data_dir, opts \\ []) do
    {width, height} = Keyword.get(opts, :window_size, @default_window_size)
    headless? = Keyword.get(opts, :headless, true)

    base = [
      "--no-sandbox",
      "--disable-gpu",
      "--disable-dev-shm-usage",
      "--disable-setuid-sandbox",
      "--no-first-run",
      "--no-default-browser-check",
      "--disable-extensions",
      "--disable-background-networking",
      "--disable-component-update",
      "--window-size=#{width},#{height}",
      "--user-data-dir=#{user_data_dir}",
      "--remote-debugging-port=0"
    ]

    headless_flag(headless?) ++ base ++ ["about:blank"]
  end

  defp headless_flag(true), do: ["--headless"]
  defp headless_flag(false), do: []

  # ── Chrome discovery ────────────────────────────────────────────────────────

  defp default_binary do
    case :os.type() do
      {:unix, :darwin} ->
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

      {:win32, _} ->
        "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe"

      {:unix, _} ->
        first_existing_linux() || "/usr/bin/google-chrome"
    end
  end

  defp first_existing_linux do
    Enum.find(
      [
        "/usr/bin/google-chrome",
        "/usr/bin/google-chrome-stable",
        "/usr/bin/chromium",
        "/usr/bin/chromium-browser",
        "/snap/bin/chromium"
      ],
      &File.exists?/1
    )
  end

  # A bare File.exists? would let a directory or a non-executable file through to
  # Port.open, which raises instead of returning {:error, {:chrome_not_found, _}}.
  # Require a regular file, and on unix the executable bit.
  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular} = stat} -> regular_executable?(stat)
      _ -> false
    end
  end

  defp regular_executable?(stat) do
    case :os.type() do
      # Windows has no unix exec bit; a regular file is enough.
      {:win32, _} -> true
      # Any of user/group/other execute bits (0o111) set.
      _ -> band(stat.mode, 0o111) != 0
    end
  end

  defp resolve_user_data_dir(opts) do
    case Keyword.get(opts, :user_data_dir) do
      nil -> {temp_dir(), true}
      dir -> {dir, false}
    end
  end

  defp temp_dir do
    Path.join(System.tmp_dir!(), "cdp_ex-#{System.unique_integer([:positive])}")
  end

  # ── DevTools URL discovery ──────────────────────────────────────────────────

  # Chrome prints `DevTools listening on ws://127.0.0.1:<port>/devtools/browser/<uuid>`
  # to stderr; if we miss it before the deadline, reconstruct from DevToolsActivePort.
  defp await_debug_url(port, dir, buffer, deadline) do
    remaining = remaining_ms(deadline)

    if remaining <= 0 do
      read_devtools_file(dir)
    else
      receive do
        {^port, {:data, data}} ->
          buffer = buffer <> data

          case Regex.run(~r{(ws://[^\s]+/devtools/browser/[0-9a-fA-F-]+)}, buffer) do
            [_, url] -> {:ok, url}
            nil -> await_debug_url(port, dir, buffer, deadline)
          end

        {^port, {:exit_status, status}} ->
          {:error, {:chrome_exited, status, String.slice(buffer, 0, 500)}}
      after
        remaining -> read_devtools_file(dir)
      end
    end
  end

  # DevToolsActivePort: line 1 is the port, line 2 is the /devtools/browser/<uuid> path.
  defp read_devtools_file(dir) do
    with {:ok, contents} <- File.read(Path.join(dir, "DevToolsActivePort")),
         [port_str, browser_path | _] <- String.split(String.trim(contents), "\n"),
         {port_num, _} <- Integer.parse(port_str) do
      {:ok, "ws://127.0.0.1:#{port_num}#{browser_path}"}
    else
      {:error, _} -> {:error, :debug_url_not_found}
      _ -> {:error, :devtools_file_malformed}
    end
  end

  # ── process control ─────────────────────────────────────────────────────────

  defp kill(nil), do: :ok

  defp kill(os_pid) do
    {cmd, args} =
      case :os.type() do
        {:win32, _} -> {"taskkill", ["/F", "/T", "/PID", to_string(os_pid)]}
        _ -> {"kill", ["-9", to_string(os_pid)]}
      end

    _ = System.cmd(cmd, args, stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  defp close_port(port) do
    Port.close(port)
    :ok
  rescue
    _ -> :ok
  end

  defp await_exit(nil, _deadline), do: :ok

  defp await_exit(os_pid, deadline) do
    if os_alive?(os_pid) and remaining_ms(deadline) > 0 do
      Process.sleep(20)
      await_exit(os_pid, deadline)
    else
      :ok
    end
  end

  # `kill -0` signals nothing but returns success only if the process exists.
  # On Windows there's no equivalent here, so skip the wait (taskkill /F /T is
  # synchronous enough).
  defp os_alive?(os_pid) do
    case :os.type() do
      {:win32, _} ->
        false

      _ ->
        case System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true) do
          {_, 0} -> true
          _ -> false
        end
    end
  rescue
    _ -> false
  end

  # Remove the profile dir, retrying until it's actually gone (a child process
  # can recreate a file between the rm and the check). Best-effort: gives up
  # quietly after a few attempts — it's a temp dir the OS will reclaim anyway.
  defp remove_dir(dir), do: remove_dir(dir, 5)
  defp remove_dir(_dir, 0), do: :ok

  defp remove_dir(dir, attempts) do
    _ = File.rm_rf(dir)

    if File.dir?(dir) do
      Process.sleep(50)
      remove_dir(dir, attempts - 1)
    else
      :ok
    end
  end

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout
  defp remaining_ms(deadline), do: deadline - System.monotonic_time(:millisecond)
end
