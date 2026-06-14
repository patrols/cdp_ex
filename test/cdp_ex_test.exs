defmodule CDPExTest do
  use ExUnit.Case, async: true

  alias Code.Typespec

  doctest CDPEx

  describe "classify_error/1" do
    # Exemplars are kept beside CDPEx.error_reason/0: every documented member appears
    # in exactly one bucket below. The "error_reason/0 coverage" test mechanically
    # enforces this — it extracts the union's members (expanding call_error/launch_error)
    # and fails if any lacks an exemplar here, so a member can't be added to the type
    # without being classified.
    #
    # The guarantee is one-directional (type -> test): it does NOT prove every error the
    # code *produces* reaches error_reason/0. A new producer wired up without updating the
    # type still falls through classify_error/1's catch-all to :unknown — that direction
    # (the original {:capture_failed, _} drift) stays a review/convention responsibility,
    # since the producing tags are scattered across {:error, _} / {:stop, _} returns and
    # can't be enumerated mechanically without a brittle source scan.

    # Re-attempt may succeed: dropped connection, dead process, timeout, launch trouble,
    # or an internal capture/idle helper crash.
    @transient [
      {:ws_closed, :closed},
      {:ws_closed, {:ws_decode, :invalid_frame}},
      {:ws_connect, :econnrefused},
      {:ws_upgrade, :upgrade_timeout},
      :noproc,
      :timeout,
      {:timeout, "Page.navigate"},
      {:timeout, :await_event},
      {:chrome_exited, 1, "stderr excerpt"},
      {:debug_url_not_found, "stdout excerpt"},
      {:devtools_file_malformed, "contents excerpt"},
      {:capture_failed, :timeout},
      {:idle_wait_failed, {:badmatch, nil}},
      {:navigate, "net::ERR_CONNECTION_REFUSED"},
      {:navigate, "net::ERR_TIMED_OUT"}
    ]

    # Deterministic: retrying the same call yields the same error (semantic, usage, or
    # validation failures, plus a missing Chrome binary and a no-document navigation).
    @terminal [
      {:chrome_not_found, "/usr/bin/google-chrome"},
      {:selector_not_found, ".missing"},
      {:not_clickable, ".hidden"},
      {:unknown_key, "F13"},
      {:evaluate_exception, %{"text" => "ReferenceError"}},
      {:unserializable_value, "NaN"},
      {:unexpected_evaluate, %{"unexpected" => true}},
      {:invalid_args, :badarg},
      {:invalid_source, :bogus},
      {:invalid_error_reason, :bogus},
      {:invalid_transport, :bogus},
      {:invalid_proxy, {:malformed_url, "nope"}},
      {:unsupported_transport, :session},
      {:unsupported_with_connect, :proxy},
      {:invalid_response_body, "not-base64"},
      {:invalid_pdf_data, "not-base64"},
      {:invalid_screenshot_data, "not-base64"},
      {:conflict, :authenticated},
      {:conflict, :intercepting},
      :unknown_page,
      :already_authenticated,
      :already_intercepting
    ]

    # Outcome depends on a payload or timing classify_error/1 deliberately does not crack
    # yet — the net::ERR_* text, the CDP error code, the file-write posix reason, or
    # whether a no-document navigation was a same-document hop vs a slow miss.
    @payload_dependent [
      {:navigate, "net::ERR_NAME_NOT_RESOLVED"},
      {:navigate, "net::ERR_BLOCKED_BY_CLIENT"},
      {:navigate, "net::ERR_ABORTED"},
      {:cdp_error, "Page.navigate", %{"code" => -32_000, "message" => "boom"}},
      {:write_failed, :eacces},
      {:write_failed, :enospc},
      {:no_document_response, "https://example.com/#hash"},
      {:connect_discovery_failed, :econnrefused}
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

    test "splits navigation net::ERR_* into connection-layer transient vs ambiguous unknown" do
      # Connection/network-layer codes — a fresh attempt may succeed.
      assert CDPEx.classify_error({:navigate, "net::ERR_CONNECTION_REFUSED"}) == :transient
      assert CDPEx.classify_error({:navigate, "net::ERR_CONNECTION_RESET"}) == :transient
      assert CDPEx.classify_error({:navigate, "net::ERR_TIMED_OUT"}) == :transient
      assert CDPEx.classify_error({:navigate, "net::ERR_INTERNET_DISCONNECTED"}) == :transient

      # Ambiguous codes — the caller decides.
      assert CDPEx.classify_error({:navigate, "net::ERR_NAME_NOT_RESOLVED"}) == :unknown
      assert CDPEx.classify_error({:navigate, "net::ERR_BLOCKED_BY_CLIENT"}) == :unknown
      assert CDPEx.classify_error({:navigate, "net::ERR_ABORTED"}) == :unknown

      # ERR_CONNECTION_TIMED_OUT must still read as transient (and not via a stray
      # ERR_TIMED_OUT substring match), and a non-string navigate payload can't be
      # inspected — both resolve cleanly rather than crashing.
      assert CDPEx.classify_error({:navigate, "net::ERR_CONNECTION_TIMED_OUT"}) == :transient
      assert CDPEx.classify_error({:navigate, :weird}) == :unknown
    end

    test "navigate net::ERR_* matching is exact-token and crash-free" do
      # Look-alikes that embed a transient code as a fragment must stay :unknown — exact
      # matching (not substring) guarantees this even against a future allowlist edit.
      # (ERR_DNS_TIMED_OUT is not ERR_TIMED_OUT; ERR_SOCKS_CONNECTION_HOST_UNREACHABLE is
      # not ERR_ADDRESS_UNREACHABLE / ERR_CONNECTION_*.)
      assert CDPEx.classify_error({:navigate, "net::ERR_DNS_TIMED_OUT"}) == :unknown

      assert CDPEx.classify_error({:navigate, "net::ERR_SOCKS_CONNECTION_HOST_UNREACHABLE"}) ==
               :unknown

      # A missing "net::" prefix, an empty string, or any non-binary payload resolves to
      # :unknown — never a crash (the is_binary guard keeps a charlist away from the match).
      assert CDPEx.classify_error({:navigate, "ERR_TIMED_OUT"}) == :unknown
      assert CDPEx.classify_error({:navigate, ""}) == :unknown
      assert CDPEx.classify_error({:navigate, ~c"net::ERR_TIMED_OUT"}) == :unknown
      assert CDPEx.classify_error({:navigate, nil}) == :unknown
    end
  end

  describe "transient?/1" do
    test "is true exactly for the transient bucket" do
      assert CDPEx.transient?({:ws_closed, :closed})
      assert CDPEx.transient?(:noproc)
      assert CDPEx.transient?({:capture_failed, :timeout})
      assert CDPEx.transient?({:navigate, "net::ERR_CONNECTION_REFUSED"})
    end

    test "is false for terminal, payload-dependent, and unrecognized reasons" do
      refute CDPEx.transient?({:selector_not_found, ".x"})
      refute CDPEx.transient?(:already_authenticated)
      refute CDPEx.transient?({:navigate, "net::ERR_NAME_NOT_RESOLVED"})
      refute CDPEx.transient?({:write_failed, :eacces})
      refute CDPEx.transient?(:some_future_atom)
    end
  end

  describe "error_reason/0 coverage" do
    test "every error_reason/0 member has a classify_error/1 exemplar" do
      exemplar_tags = MapSet.new(@transient ++ @terminal ++ @payload_dependent, &reason_tag/1)

      missing = MapSet.difference(error_reason_member_tags(), exemplar_tags)

      assert MapSet.equal?(missing, MapSet.new()),
             "error_reason/0 members with no classify_error/1 exemplar — add each to a " <>
               "bucket above and give it a classify_error/1 clause: " <>
               inspect(MapSet.to_list(missing))
    end
  end

  # The tag of an exemplar reason: a tuple's first element, else the bare atom itself.
  defp reason_tag(reason) when is_tuple(reason), do: elem(reason, 0)
  defp reason_tag(reason), do: reason

  # The set of member "tags" of CDPEx.error_reason/0, read from the compiled type AST,
  # expanding the two machine-checked remote sub-unions (call_error, launch_error). This
  # is what makes the exemplar lists exhaustive against the type rather than by convention.
  defp error_reason_member_tags, do: union_member_tags(CDPEx, :error_reason)

  defp union_member_tags(module, type_name) do
    {:ok, types} = Typespec.fetch_types(module)

    {_kind, {^type_name, ast, _args}} =
      Enum.find(types, fn {_, {name, _, _}} -> name == type_name end)

    ast |> collect_tags() |> MapSet.new()
  end

  defp collect_tags({:type, _, :union, members}), do: Enum.flat_map(members, &collect_tags/1)
  defp collect_tags({:atom, _, atom}), do: [atom]
  defp collect_tags({:type, _, :tuple, [{:atom, _, tag} | _]}), do: [tag]

  defp collect_tags({:remote_type, _, [{:atom, _, mod}, {:atom, _, name}, _]}),
    do: MapSet.to_list(union_member_tags(mod, name))

  # Fail loudly on an unrecognized member shape rather than silently dropping it — a
  # dropped member would escape the exemplar-coverage check this test exists to enforce
  # (e.g. a tuple not tagged by a bare atom, a local-type alias, or a built-in). Add an
  # explicit clause for any legitimately tag-less shape so each is a deliberate decision.
  defp collect_tags(other), do: raise("unhandled error_reason member AST shape: #{inspect(other)}")
end
