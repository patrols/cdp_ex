defmodule CDPExTest do
  use ExUnit.Case, async: true

  doctest CDPEx

  describe "classify_error/1" do
    # Exemplars are kept beside CDPEx.error_reason/0: every documented member appears
    # in exactly one bucket below. A new error_reason kind should be added here (and to
    # classify_error/1) in the same change — otherwise it falls through to :unknown and
    # the "no recognized reason is :unknown" assertion below won't cover it, which is the
    # prompt to classify it deliberately.

    # Re-attempt may succeed: dropped connection, dead process, timeout, launch trouble,
    # or an internal capture/idle helper crash.
    @transient [
      {:ws_closed, :closed},
      {:ws_closed, {:ws_decode, :invalid_frame}},
      :noproc,
      :timeout,
      {:timeout, "Page.navigate"},
      {:timeout, :await_event},
      {:chrome_exited, 1, "stderr excerpt"},
      {:debug_url_not_found, "stdout excerpt"},
      {:devtools_file_malformed, "contents excerpt"},
      {:capture_failed, :timeout},
      {:idle_wait_failed, {:badmatch, nil}}
    ]

    # Deterministic: retrying the same call yields the same error (semantic, usage, or
    # validation failures, plus a missing Chrome binary and a no-document navigation).
    @terminal [
      {:chrome_not_found, "/usr/bin/google-chrome"},
      {:no_document_response, "https://example.com/#hash"},
      {:selector_not_found, ".missing"},
      {:evaluate_exception, %{"text" => "ReferenceError"}},
      {:unexpected_evaluate, %{"unexpected" => true}},
      {:invalid_args, :badarg},
      {:invalid_source, :bogus},
      {:invalid_error_reason, :bogus},
      {:invalid_transport, :bogus},
      {:unsupported_transport, :session},
      {:invalid_response_body, "not-base64"},
      {:invalid_pdf_data, "not-base64"},
      {:invalid_screenshot_data, "not-base64"},
      {:conflict, :authenticated},
      {:conflict, :intercepting},
      :unknown_page,
      :already_authenticated,
      :already_intercepting
    ]

    # Outcome depends on a payload classify_error/1 deliberately does not crack yet —
    # the net::ERR_* text, the CDP error code, the file-write posix reason.
    @payload_dependent [
      {:navigate, "net::ERR_NAME_NOT_RESOLVED"},
      {:navigate, "net::ERR_CONNECTION_REFUSED"},
      {:cdp_error, "Page.navigate", %{"code" => -32_000, "message" => "boom"}},
      {:write_failed, :eacces},
      {:write_failed, :enospc}
    ]

    # Reasons CDPEx never produces — a future shape or a foreign wrapped term.
    @unrecognized [
      :some_future_atom,
      {:some_future_tag, 1},
      {:totally, :unknown, :shape},
      "a string reason",
      %{not: "a tuple"},
      nil
    ]

    test "buckets connection/process/launch/helper failures as :transient" do
      for reason <- @transient do
        assert CDPEx.classify_error(reason) == :transient,
               "expected #{inspect(reason)} to be :transient"
      end
    end

    test "buckets deterministic failures as :terminal" do
      for reason <- @terminal do
        assert CDPEx.classify_error(reason) == :terminal,
               "expected #{inspect(reason)} to be :terminal"
      end
    end

    test "leaves payload-dependent reasons :unknown (deliberately, not by fallthrough)" do
      for reason <- @payload_dependent do
        assert CDPEx.classify_error(reason) == :unknown,
               "expected #{inspect(reason)} to be :unknown"
      end
    end

    test "classifies unrecognized terms as :unknown" do
      for reason <- @unrecognized do
        assert CDPEx.classify_error(reason) == :unknown,
               "expected #{inspect(reason)} to be :unknown"
      end
    end

    test "no recognized transient/terminal reason falls through to :unknown" do
      # Guards against a typo'd or missing clause: a recognized reason must never be
      # :unknown. (The :unknown bucket is reserved for @payload_dependent + @unrecognized.)
      for reason <- @transient ++ @terminal do
        refute CDPEx.classify_error(reason) == :unknown,
               "#{inspect(reason)} unexpectedly classified as :unknown"
      end
    end
  end

  describe "transient?/1" do
    test "is true exactly for the transient bucket" do
      assert CDPEx.transient?({:ws_closed, :closed})
      assert CDPEx.transient?(:noproc)
      assert CDPEx.transient?({:capture_failed, :timeout})
    end

    test "is false for terminal, payload-dependent, and unrecognized reasons" do
      refute CDPEx.transient?({:selector_not_found, ".x"})
      refute CDPEx.transient?(:already_authenticated)
      refute CDPEx.transient?({:navigate, "net::ERR_NAME_NOT_RESOLVED"})
      refute CDPEx.transient?({:write_failed, :eacces})
      refute CDPEx.transient?(:some_future_atom)
    end
  end
end
