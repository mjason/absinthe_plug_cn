defmodule Absinthe.Plug.GraphiQL do
  @moduledoc """
  Provides a GraphiQL interface.

  ## Examples

  Serve the GraphiQL "advanced" interface at `/graphiql`, but only in
  development:

      if Mix.env == :dev do
        forward "/graphiql",
          Absinthe.Plug.GraphiQL,
          schema: MyApp.Schema
      end

  Use the "simple" interface (original GraphiQL) instead:

      if Mix.env == :dev do
        forward "/graphiql",
          Absinthe.Plug.GraphiQL,
          schema: MyApp.Schema,
          interface: :simple

  ## Interface Selection

  The GraphiQL interface can be switched using the `:interface` option.

  - `:advanced` (default) will serve the [GraphiQL Workspace](https://github.com/OlegIlyenko/graphiql-workspace) interface from Oleg Ilyenko.
  - `:simple` will serve the original [GraphiQL](https://github.com/graphql/graphiql) interface from Facebook.

  See `Absinthe.Plug` for the other  options.
  """

  require EEx
  @graphiql_version "0.9.3"
  EEx.function_from_file :defp, :graphiql_html, Path.join(__DIR__, "graphiql.html.eex"),
    [:graphiql_version, :query_string, :variables_string, :result_string]

  @graphiql_workspace_version "1.0.4"
  EEx.function_from_file :defp, :graphiql_workspace_html, Path.join(__DIR__, "graphiql_workspace.html.eex"),
    [:graphiql_workspace_version, :query_string, :variables_string]

  @behaviour Plug

  import Plug.Conn

  @type opts :: [
    schema: atom,
    adapter: atom,
    path: binary,
    context: map,
    json_codec: atom | {atom, Keyword.t},
    interface: :advanced | :simple
  ]

  @doc false
  @spec init(opts :: opts) :: map
  def init(opts) do
    opts
    |> Absinthe.Plug.init
    |> Map.put(:interface, Keyword.get(opts, :interface) || :advanced)
  end

  @doc false
  def call(conn, config) do
    case html?(conn) do
      true -> do_call(conn, config)
      _ -> Absinthe.Plug.call(conn, config)
    end
  end

  defp html?(conn) do
    Plug.Conn.get_req_header(conn, "accept")
    |> List.first
    |> case do
      string when is_binary(string) ->
        String.contains?(string, "text/html")
      _ ->
        false
    end
  end

  defp do_call(conn, %{json_codec: _, interface: interface} = config) do
    with {:ok, conn, request} <- Absinthe.Plug.Request.parse(conn, config),
         {:process, request} <- select_mode(request),
         {:ok, request} <- Absinthe.Plug.ensure_processable(request, config),
         :ok <- Absinthe.Plug.Request.log(request) do

      conn_info = %{
        conn_private: (conn.private[:absinthe] || %{}) |> Map.put(:http_method, conn.method),
      }

      case Absinthe.Plug.run_request(request, conn_info, config) do
        {:ok, result} ->
          query = hd(request.queries) # GraphiQL doesn't batch requests, so the first query is the only one
          {:ok, conn, result, query.variables, query.document || ""}
        other -> other
      end
    end
    |> case do
      {:ok, conn, result, variables, query} ->
        query = query |> js_escape

        var_string = variables
        |> Poison.encode!(pretty: true)
        |> js_escape

        result = result
        |> Poison.encode!(pretty: true)
        |> js_escape

        conn
        |> render_interface(interface, query: query, var_string: var_string, result: result)

      {:input_error, msg} ->
        conn
        |> send_resp(400, msg)

      :start_interface ->
         conn
         |> render_interface(interface)

      {:error, {:http_method, text}, _} ->
        conn
        |> send_resp(405, text)

      {:error, error, _} when is_binary(error) ->
        conn
        |> send_resp(500, error)

    end
  end

  @spec select_mode(request :: Absinthe.Plug.Request.t) :: :start_interface | {:process, Absinthe.Plug.Request.t}
  defp select_mode(%{queries: [%Absinthe.Plug.Request.Query{document: nil}]}), do: :start_interface
  defp select_mode(request), do: {:process, request}

  @render_defaults [query: "", var_string: "", results: ""]

  @spec render_interface(conn :: Conn.t, interface :: :advanced | :simple, opts :: Keyword.t) :: Conn.t
  defp render_interface(conn, interface, opts \\ [])
  defp render_interface(conn, :simple, opts) do
    opts = Keyword.merge(@render_defaults, opts)
    graphiql_html(
      @graphiql_version,
      opts[:query], opts[:var_string], opts[:result]
    )
    |> rendered(conn)
  end
  defp render_interface(conn, :advanced, opts) do
    opts = Keyword.merge(@render_defaults, opts)
    graphiql_workspace_html(
      @graphiql_workspace_version,
      opts[:query], opts[:var_string]
    )
    |> rendered(conn)
  end

  @spec rendered(String.t, Plug.Conn.t) :: Conn.t
  defp rendered(html, conn) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html)
  end

  defp js_escape(string) do
    string
    |> String.replace(~r/\n/, "\\n")
    |> String.replace(~r/'/, "\\'")
  end
end
