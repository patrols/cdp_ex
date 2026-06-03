defmodule CDPEx.FetchTest do
  use ExUnit.Case, async: true

  alias CDPEx.Fetch

  @creds [username: "u", password: "p"]

  describe "auth_decision/5" do
    test "provides credentials for a matching challenge and records the attempt" do
      {response, attempts} = Fetch.auth_decision(:any, %{}, "R1", %{"source" => "Server"}, @creds)

      assert response == %{
               "response" => "ProvideCredentials",
               "username" => "u",
               "password" => "p"
             }

      assert attempts == %{"R1" => 1}
    end

    test "cancels on the second challenge for the same request (rejected credentials)" do
      {response, attempts} =
        Fetch.auth_decision(:any, %{"R1" => 1}, "R1", %{"source" => "Server"}, @creds)

      assert response == %{"response" => "CancelAuth"}
      refute Map.has_key?(attempts, "R1")
    end

    test "the :proxy filter answers only Proxy challenges" do
      assert {%{"response" => "Default"}, %{}} =
               Fetch.auth_decision(:proxy, %{}, "R1", %{"source" => "Server"}, @creds)

      assert {%{"response" => "ProvideCredentials"}, %{"R1" => 1}} =
               Fetch.auth_decision(:proxy, %{}, "R1", %{"source" => "Proxy"}, @creds)
    end

    test "the :server filter answers only Server challenges" do
      assert {%{"response" => "ProvideCredentials"}, %{"R1" => 1}} =
               Fetch.auth_decision(:server, %{}, "R1", %{"source" => "Server"}, @creds)

      assert {%{"response" => "Default"}, %{}} =
               Fetch.auth_decision(:server, %{}, "R1", %{"source" => "Proxy"}, @creds)
    end
  end
end
