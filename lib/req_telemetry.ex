defmodule ReqTelemetry do
  @external_resource "README.md"
  @moduledoc "README.md" |> File.read!() |> String.split("<!-- MDOC !-->") |> Enum.fetch!(1)

  require Logger

  @type options :: boolean() | [option]
  @type option :: {:adapter, boolean()} | {:pipeline, boolean()} | {:metadata, map()}

  @default_opts %{adapter: true, pipeline: true, metadata: nil}
  @no_emit_opts %{adapter: false, pipeline: false, metadata: nil}

  @adapter_events [
    [:req, :request, :adapter, :start],
    [:req, :request, :adapter, :stop],
    [:req, :request, :adapter, :error]
  ]

  @pipeline_events [
    [:req, :request, :pipeline, :start],
    [:req, :request, :pipeline, :stop],
    [:req, :request, :pipeline, :error]
  ]

  @all_events @adapter_events ++ @pipeline_events

  @doc """
  Installs request, response, and error steps that emit `:telemetry` events.

  ## Options

    * `:pipeline` (default `true`) - emit pipeline telemetry events
    * `:adapter` (default `true`) - emit adapter telemetry events
    * `:metadata` (default `nil`) - map of user-supplied metadata available in telemetry handlers

  As a shortcut, all events can be suppressed by passing `false` instead of an options list.

  These same options can also be passed through `Req` options under the `:telemetry` key to
  change the behavior on a per-request basis. Maps of metadata will be merged. For example:

      req = Req.new() |> ReqTelemetry.attach(metadata: %{api_version: 1})

      Req.get!(req,
        url: "https://api.example.org/endpoint",
        telemetry: [metadata: %{endpoint: "endpoint"}]
      )

      # Your telemetry event handler will have access to the merged map
      def handle_event(
        [:req, _, _, _],
        _measurements,
        %{metadata: %{api_version: v, endpoint: e}},
        _config
      ) do
        # ...
      end

  ## Examples

  Emit all events by default, limiting them per-request as needed.

      req = Req.new() |> ReqTelemetry.attach()

      # Emits all events
      Req.get!(req, url: "https://example.org")

      # Do not emit events
      Req.get!(req, url: "https://example.org", telemetry: false)

      # Emit adapter events but not pipeline events
      Req.get!(req, url: "https://example.org", telemetry: [pipeline: false])

  Suppress all events by default, enabling them per-request as needed.

      req = Req.new() |> ReqTelemetry.attach(false)

      # Will not emit events
      Req.get!(req, url: "https://example.org")

      # Override to emit events
      Req.get!(req, url: "https://example.org", telemetry: true)

      # Override to emit only adapter events
      Req.get!(req, url: "https://example.org", telemetry: [adapter: true])

  Finally, suppress only a certain kind of event by default, overriding that default as needed.

      req = Req.new() |> ReqTelemetry.attach(pipeline: false)

      # Will only emit adapter events
      Req.get!(req, url: "https://example.org")

      # Override to emit only pipeline events
      Req.get!(req, url: "https://example.org", telemetry: [pipeline: true, adapter: false])

  """
  @spec attach(Req.Request.t(), options) :: Req.Request.t()
  def attach(%Req.Request{} = req, opts \\ []) do
    initial_opts =
      case normalize_opts(opts) do
        {:ok, opts} -> Map.merge(@default_opts, opts)
        {:error, opts} -> options_error!(opts)
      end

    initial_opts = Map.put_new(initial_opts, :metadata, nil)

    req
    |> Req.Request.register_options([:telemetry])
    |> Req.Request.put_private(:telemetry, %{initial_opts: initial_opts})
    # Pipeline events occur at start of request and end of response/error
    |> Req.Request.prepend_request_steps(pipeline_start: &emit_start(&1, :pipeline))
    |> Req.Request.append_response_steps(pipeline_stop: &emit_stop(&1, :pipeline))
    |> Req.Request.append_error_steps(pipeline_error: &emit_error(&1, :pipeline))
    # Adapter events occur at end of request and start of response/error
    |> Req.Request.append_request_steps(adapter_start: &emit_start(&1, :adapter))
    |> Req.Request.prepend_response_steps(adapter_stop: &emit_stop(&1, :adapter))
    |> Req.Request.prepend_error_steps(adapter_error: &emit_error(&1, :adapter))
    # Prepend setup at the end to ensure it is run first
    |> Req.Request.prepend_request_steps(telemetry_setup: &telemetry_setup/1)
  end

  @doc """
  Returns a list of events emitted by `ReqTelemetry`.
  """
  @spec events(:all | :pipeline | :adapter) :: [:telemetry.event_name(), ...]
  def events(kind \\ :all)
  def events(:all), do: @all_events
  def events(:pipeline), do: @pipeline_events
  def events(:adapter), do: @adapter_events

  @doc """
  Attach a basic telemetry event handler that logs `ReqTelemetry` events.

  ## Usage

  Telemetry event handlers can be attached in your application's `start/2` callback:

      @impl true
      def start(_type, _args) do
        ReqTelemetry.attach_default_logger()

        children = [
          ...
        ]

        Supervisor.start_link(...)
      end

  All events are logged by default, but this can be overridden by passing in a keyword describing
  the kind of events to log or a list of specific events to log.

      # Logs all events
      :ok = ReqTelemetry.attach_default_logger()

      # Logs only adapter events
      :ok = ReqTelemetry.attach_default_logger(:adapter)

      # Logs only pipeline errors
      :ok = ReqTelemetry.attach_default_logger([[:req, :request, :pipeline, :error]])

  ## Example

  Here's what a successful request might look like:

      15:52:01.462 [info] Req:479128347 - GET https://example.org (pipeline)
      15:52:01.466 [info] Req:479128347 - GET https://example.org (adapter)
      15:52:01.869 [info] Req:479128347 - 200 in 403ms (adapter)
      15:52:01.875 [info] Req:479128347 - 200 in 413ms (pipeline)

  And here's what an error might look like:

      15:52:04.174 [error] Req:42446822 - ERROR in 2012ms (adapter)
      %Finch.Error{reason: :request_timeout}

  """
  @spec attach_default_logger(:all | :adapter | :pipeline | [:telemetry.event_name(), ...]) ::
          :ok | {:error, :already_exists}
  def attach_default_logger(kind_or_events \\ :all)

  def attach_default_logger(kind) when is_atom(kind) do
    kind
    |> events()
    |> attach_default_logger()
  end

  def attach_default_logger(events) when is_list(events) do
    unknown_events = events -- @all_events

    unless unknown_events == [] do
      raise ArgumentError, """
      cannot attach ReqTelemetry logger to unknown events: #{inspect(unknown_events)}
      """
    end

    :telemetry.attach_many(
      "req-telemetry-handler",
      events,
      &ReqTelemetry.Logger.handle_event/4,
      nil
    )
  end

  @doc false
  def telemetry_setup(%Req.Request{} = req) do
    private = Req.Request.get_private(req, :telemetry)
    req = Req.Request.put_private(req, :telemetry, Map.put(private, :ref, make_ref()))

    case fetch_options(req) do
      {:ok, opts} ->
        Req.Request.merge_options(req, telemetry: opts)

      {:error, opts} ->
        Logger.warning(options_error(opts) <> "\nEvents will not be emitted.")
        Req.Request.merge_options(req, telemetry: @no_emit_opts)
    end
  end

  @doc false
  def fetch_options(%Req.Request{options: options} = req) do
    initial_opts = req |> Req.Request.get_private(:telemetry) |> Map.fetch!(:initial_opts)

    case options |> Map.get(:telemetry, %{}) |> normalize_opts() do
      {:ok, opts} -> {:ok, Map.merge(initial_opts, opts, &merge_opt/3)}
      {:error, opts} -> {:error, opts}
    end
  end

  defp merge_opt(:metadata, %{} = left, %{} = right), do: Map.merge(left, right)
  defp merge_opt(_key, _left, right), do: right

  @doc false
  def emit_start(req, event) do
    start_time = System.monotonic_time()

    if emit?(req, event) do
      %{ref: ref} = private = Req.Request.get_private(req, :telemetry)
      %{url: url, method: method, headers: headers} = req

      :telemetry.execute(
        [:req, :request, event, :start],
        %{time: System.system_time()},
        %{ref: ref, url: url, method: method, headers: headers, metadata: metadata(req)}
      )

      Req.Request.put_private(req, :telemetry, Map.put(private, event, start_time))
    else
      req
    end
  end

  @doc false
  def emit_stop({req, resp}, event) do
    stop_time = System.monotonic_time()

    if emit?(req, event) do
      %{ref: ref} = Req.Request.get_private(req, :telemetry)
      %{url: url, method: method} = req
      %{status: status, headers: headers} = resp

      :telemetry.execute(
        [:req, :request, event, :stop],
        %{duration: duration(req, event, stop_time)},
        %{
          ref: ref,
          url: url,
          method: method,
          status: status,
          resp_headers: headers,
          metadata: metadata(req)
        }
      )
    end

    {req, resp}
  end

  @doc false
  def emit_error({req, exception}, event) do
    stop_time = System.monotonic_time()

    if emit?(req, event) do
      %{ref: ref} = Req.Request.get_private(req, :telemetry)
      %{url: url, method: method, headers: headers} = req

      :telemetry.execute(
        [:req, :request, event, :error],
        %{duration: duration(req, event, stop_time)},
        %{
          ref: ref,
          url: url,
          method: method,
          headers: headers,
          error: exception,
          metadata: metadata(req)
        }
      )
    end

    {req, exception}
  end

  defp metadata(%{options: %{telemetry: %{metadata: metadata}}}), do: metadata
  defp metadata(_req), do: nil

  defp normalize_opts(true), do: {:ok, @default_opts}
  defp normalize_opts(false), do: {:ok, @no_emit_opts}

  defp normalize_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      normalize_opts(Map.new(opts))
    else
      {:error, opts}
    end
  end

  defp normalize_opts(opts) when is_map(opts) do
    if valid_opts?(opts), do: {:ok, opts}, else: {:error, opts}
  end

  defp normalize_opts(opts), do: {:error, opts}

  defp valid_opts?(opts) when is_map(opts) do
    Map.keys(opts) -- [:adapter, :pipeline, :metadata] == []
  end

  defp valid_opts?(_), do: false

  defp options_error!(opts) do
    raise ArgumentError, options_error(opts)
  end

  defp options_error(opts) do
    """
    Invalid `ReqTelemetry` options. Valid options must be a boolean
    or a keyword list/map containing `:adapter` and/or `:pipeline` keys.

    Got: #{inspect(opts)}
    """
  end

  defp emit?(%{options: %{telemetry: opts}}, event), do: opts[event]

  defp duration(req, event, stop_time) do
    req
    |> Req.Request.get_private(:telemetry, %{})
    |> Map.get(event)
    |> case do
      nil -> nil
      start_time -> stop_time - start_time
    end
  end
end
