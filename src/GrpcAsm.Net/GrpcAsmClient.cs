using System.Buffers;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Channels;
using Google.Protobuf;
using Grpc.Core;

namespace GrpcAsm.Net;

/// <summary>Options of a <see cref="GrpcAsmClient"/>. Zero (or null) means the default.</summary>
public sealed class GrpcAsmClientOptions
{
    /// <summary>Largest response message accepted, bytes; 0: 4 MiB. A larger one fails RESOURCE_EXHAUSTED.</summary>
    public int MaxResponseBytes { get; set; }

    /// <summary>Calls in flight on the connection, 1..65536; 0: 1000. More wait in order.</summary>
    public int MaxConcurrentCalls { get; set; }

    /// <summary>The :authority of every call; null: "host:port" ("[host]:port" for IPv6).</summary>
    public string? Authority { get; set; }
}

/// <summary>A method registered on a <see cref="GrpcAsmClient"/> (<see cref="GrpcAsmClient.Method"/>).</summary>
/// <param name="Handle">The native client's handle for the path.</param>
/// <param name="Path">The method's path.</param>
public readonly record struct GrpcAsmMethod(int Handle, string Path);

/// <summary>
/// A gRPC client over one HTTP/2 connection whose protocol work — HTTP/2, HPACK with cached
/// header blocks, response parsing — is GrpcAsm's assembly client; .NET does the socket I/O.
/// </summary>
/// <remarks>
/// <para>
/// Thread-safe: <see cref="CallAsync(GrpcAsmMethod, ReadOnlySpan{byte})"/> may be called from
/// any thread. A lock serializes the native client (which is single-threaded by design); its
/// critical sections are the native calls only — issuing a call, or processing one received
/// chunk — never I/O. The bytes the client queues are copied out under the lock and sent by one
/// sender task, which coalesces what is waiting into one send; one receive loop feeds what
/// arrives. Completions resolve Tasks whose continuations run asynchronously, never inside the
/// native callback.
/// </para>
/// <para>
/// Errors arrive as <see cref="RpcException"/>: the server's status, or one the client produced
/// (UNAVAILABLE when the connection ends, INTERNAL for a malformed response, CANCELLED for calls
/// still running at <see cref="DisposeAsync"/>).
/// </para>
/// <para>
/// Footgun: after the server's GOAWAY, or once the connection has used its 2^30 stream ids,
/// new calls fail UNAVAILABLE: open a new client.
/// </para>
/// </remarks>
public sealed class GrpcAsmClient : IAsyncDisposable
{
    /// <summary>Serializes every native call: the native client is single-threaded.</summary>
    private readonly object _sync = new();

    /// <summary>The C ABI's <c>grpcasm_client*</c>; 0 once torn down.</summary>
    private nint _client;

    /// <summary>The connection.</summary>
    private readonly Socket _socket;

    /// <summary>Output copied out of the native client, in order, for the sender task.</summary>
    private readonly Channel<byte[]> _output = Channel.CreateUnbounded<byte[]>(
        new UnboundedChannelOptions { SingleReader = true });

    /// <summary>The receive loop.</summary>
    private readonly Task _receiver;

    /// <summary>The sender task.</summary>
    private readonly Task _sender;

    /// <summary>Why the connection ended (calls then fail UNAVAILABLE with it), or null.</summary>
    private volatile string? _lostReason;

    /// <summary>Takes over a connected socket and a fresh native client, and starts the loops.</summary>
    /// <param name="socket">The connected socket.</param>
    /// <param name="client">The native client (bytes mode), its output holding the preface.</param>
    private GrpcAsmClient(Socket socket, nint client)
    {
        _socket = socket;
        _client = client;
        lock (_sync)
        {
            FlushLocked(); // the HTTP/2 connection preface
        }

        _sender = Task.Run(SendLoopAsync);
        _receiver = Task.Run(ReceiveLoopAsync);
    }

    /// <summary>Connects to a gRPC server over cleartext HTTP/2 (h2c, prior knowledge).</summary>
    /// <param name="host">A host name or address.</param>
    /// <param name="port">The server's port.</param>
    /// <param name="options">Options, or null.</param>
    /// <param name="cancellationToken">Cancels the TCP connect.</param>
    /// <returns>The client. Calls may be issued at once (the protocol's defaults apply until the server's SETTINGS arrive).</returns>
    /// <exception cref="ArgumentNullException">The host is null.</exception>
    /// <exception cref="ArgumentOutOfRangeException">An option is out of range.</exception>
    /// <exception cref="SocketException">The connection failed.</exception>
    /// <exception cref="OutOfMemoryException">The native client could not be allocated.</exception>
    /// <exception cref="OperationCanceledException">The token was cancelled during the connect.</exception>
    /// <exception cref="DllNotFoundException">libgrpcasm.so cannot be loaded (not Linux x64, or not deployed).</exception>
    /// <exception cref="BadImageFormatException">The loaded libgrpcasm.so has another ABI version.</exception>
    public static async Task<GrpcAsmClient> ConnectAsync(string host, int port, GrpcAsmClientOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(host);
        // Before the TCP connect: a missing or mismatched library is a deployment error, and
        // no connection should be opened (and dropped) to find it out.
        Native.RequireCompatibleLibrary();
        options ??= new GrpcAsmClientOptions();
        var socket = new Socket(SocketType.Stream, ProtocolType.Tcp) { NoDelay = true };
        try
        {
            await socket.ConnectAsync(host, port, cancellationToken).ConfigureAwait(false);
            string authority = options.Authority ?? (host.Contains(':') ? $"[{host}]:{port}" : $"{host}:{port}");
            return new GrpcAsmClient(socket, NewNative(options, authority));
        }
        catch
        {
            socket.Dispose();
            throw;
        }
    }

    /// <summary>Creates the native client in bytes mode.</summary>
    /// <param name="options">The options.</param>
    /// <param name="authority">The :authority.</param>
    /// <returns>The <c>grpcasm_client*</c>.</returns>
    /// <exception cref="ArgumentOutOfRangeException">An option is out of range.</exception>
    /// <exception cref="OutOfMemoryException">The allocation failed.</exception>
    private static unsafe nint NewNative(GrpcAsmClientOptions options, string authority)
    {
        byte[] utf8 = Encoding.UTF8.GetBytes(authority + "\0");
        nint client;
        int rc;
        fixed (byte* a = utf8)
        {
            var native = new ClientOptions
            {
                Size = (uint)sizeof(ClientOptions),
                MaxResponseBytes = checked((uint)options.MaxResponseBytes),
                MaxConcurrentCalls = checked((uint)options.MaxConcurrentCalls),
                Authority = a,
            };
            rc = Native.ClientNew(&native, &client);
        }

        return rc switch
        {
            0 => client,
            -Native.EINVAL => throw new ArgumentOutOfRangeException(nameof(options), "an option is out of range (see GrpcAsmClientOptions)"),
            _ => throw new OutOfMemoryException("grpcasm_client_new failed"),
        };
    }

    /// <summary>Registers a method's path (or finds it registered) for calls.</summary>
    /// <param name="path">"/package.Service/Method", 1..2048 bytes.</param>
    /// <returns>The method, valid for this client's lifetime.</returns>
    /// <exception cref="ArgumentNullException">The path is null.</exception>
    /// <exception cref="ArgumentException">The path is malformed.</exception>
    /// <exception cref="ObjectDisposedException">The client is disposed, or its connection ended.</exception>
    /// <remarks>Register once, call many times: the handle is what lets the native client reuse the method's encoded header block.</remarks>
    public unsafe GrpcAsmMethod Method(string path)
    {
        ArgumentNullException.ThrowIfNull(path);
        byte[] utf8 = Encoding.UTF8.GetBytes(path + "\0");
        int rc;
        lock (_sync)
        {
            ObjectDisposedException.ThrowIf(_client == 0, this);
            fixed (byte* p = utf8)
            {
                rc = Native.ClientMethod(_client, p);
            }
        }

        return rc >= 0
            ? new GrpcAsmMethod(rc, path)
            : throw new ArgumentException($"malformed method path: {path}", nameof(path));
    }

    /// <summary>Issues a unary call with a raw request.</summary>
    /// <param name="method">The method (from <see cref="Method"/>).</param>
    /// <param name="request">The request message (protobuf bytes, without gRPC framing); copied before this returns.</param>
    /// <returns>The response message's bytes; faults with <see cref="RpcException"/> for a status other than OK.</returns>
    /// <remarks>
    /// The request is framed into the native client's output and handed to the sender task
    /// before this returns, so calls issued back to back leave together. The returned Task
    /// carries every error, including a refused call (no exception escapes this method).
    /// </remarks>
    public unsafe Task<byte[]> CallAsync(GrpcAsmMethod method, ReadOnlySpan<byte> request)
    {
        var pending = new PendingCall(this);
        GCHandle handle = GCHandle.Alloc(pending);
        int rc;
        lock (_sync)
        {
            if (_client == 0)
            {
                handle.Free();
                return Task.FromException<byte[]>(new RpcException(
                    new Status(StatusCode.Unavailable, _lostReason ?? "client disposed")));
            }

            fixed (byte* p = request)
            {
                rc = Native.ClientCall(_client, method.Handle, p, (nuint)request.Length, &OnDone,
                    GCHandle.ToIntPtr(handle));
            }

            if (rc == 0)
            {
                FlushLocked();
            }
        }

        if (rc != 0)
        {
            handle.Free();
            return Task.FromException<byte[]>(RefusalOf(rc));
        }

        return pending.Task;
    }

    /// <summary>Issues a unary call with Google.Protobuf messages.</summary>
    /// <typeparam name="TRequest">The request message type.</typeparam>
    /// <typeparam name="TResponse">The response message type.</typeparam>
    /// <param name="method">The method (from <see cref="Method"/>).</param>
    /// <param name="request">The request.</param>
    /// <param name="responseParser">The response type's parser (TResponse.Parser).</param>
    /// <returns>The response; faults with <see cref="RpcException"/> for an error status.</returns>
    /// <exception cref="ArgumentNullException">The request or the parser is null.</exception>
    /// <remarks>The request is serialized on the stack (up to 1 KiB) or into a rented buffer, then copied once by the native client.</remarks>
    public Task<TResponse> CallAsync<TRequest, TResponse>(GrpcAsmMethod method, TRequest request,
        MessageParser<TResponse> responseParser)
        where TRequest : IMessage<TRequest>
        where TResponse : IMessage<TResponse>
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(responseParser);
        int size = request.CalculateSize();
        Task<byte[]> call;
        if (size <= 1024)
        {
            Span<byte> buffer = stackalloc byte[size];
            request.WriteTo(buffer);
            call = CallAsync(method, buffer);
        }
        else
        {
            byte[] rented = ArrayPool<byte>.Shared.Rent(size);
            try
            {
                request.WriteTo(rented.AsSpan(0, size));
                call = CallAsync(method, rented.AsSpan(0, size));
            }
            finally
            {
                ArrayPool<byte>.Shared.Return(rented);
            }
        }

        return ParseAsync(call, responseParser);
    }

    /// <summary>Awaits a raw call and parses its response.</summary>
    /// <typeparam name="TResponse">The response type.</typeparam>
    /// <param name="call">The raw call.</param>
    /// <param name="parser">The parser.</param>
    /// <returns>The parsed response.</returns>
    /// <exception cref="RpcException">The call failed; or INTERNAL, the response is not a valid TResponse.</exception>
    private static async Task<TResponse> ParseAsync<TResponse>(Task<byte[]> call, MessageParser<TResponse> parser)
        where TResponse : IMessage<TResponse>
    {
        byte[] bytes = await call.ConfigureAwait(false);
        try
        {
            return parser.ParseFrom(bytes);
        }
        catch (InvalidProtocolBufferException e)
        {
            throw new RpcException(new Status(StatusCode.Internal, "malformed response message", e));
        }
    }

    /// <summary>Closes the connection; calls still running fail CANCELLED "client closed".</summary>
    /// <returns>A task that completes when both loops have ended.</returns>
    public async ValueTask DisposeAsync()
    {
        Teardown(lost: null);
        try
        {
            await Task.WhenAll(_receiver, _sender).ConfigureAwait(false);
        }
        catch (Exception)
        {
            // The loops end through the socket's disposal; their exceptions are expected here.
        }
    }

    /// <summary>
    /// Moves the native client's queued output to the sender task. Callers hold <see cref="_sync"/>.
    /// </summary>
    private unsafe void FlushLocked()
    {
        byte* data;
        nuint n = Native.ClientOutput(_client, &data);
        if (n == 0)
        {
            return;
        }

        byte[] copy = new ReadOnlySpan<byte>(data, checked((int)n)).ToArray();
        Native.ClientConsume(_client, n);
        _output.Writer.TryWrite(copy); // unbounded: never refused while the client lives
    }

    /// <summary>
    /// Feeds every received chunk to the native client (completions run inside), then flushes
    /// what it queued in answer (acknowledgements, WINDOW_UPDATE).
    /// </summary>
    /// <returns>A task that ends when the connection does.</returns>
    private async Task ReceiveLoopAsync()
    {
        // Pinned: the native client reads it during ClientInput without a fixed block's churn.
        byte[] buffer = GC.AllocateUninitializedArray<byte>(256 * 1024, pinned: true);
        string reason = "connection closed by the server";
        try
        {
            while (true)
            {
                int n = await _socket.ReceiveAsync(buffer, SocketFlags.None).ConfigureAwait(false);
                if (n == 0)
                {
                    break;
                }

                int rc = Input(buffer, n);
                if (rc == int.MinValue)
                {
                    return; // disposed meanwhile
                }

                if (rc < 0)
                {
                    reason = "connection failed (HTTP/2 protocol error)";
                    break;
                }
            }
        }
        catch (SocketException e)
        {
            reason = $"connection lost ({e.SocketErrorCode})";
        }
        catch (ObjectDisposedException)
        {
            return; // the client was disposed
        }

        Teardown(reason);
    }

    /// <summary>
    /// Hands one received chunk to the native client under the lock (completions run inside),
    /// then flushes what it queued in answer. Synchronous because it pins the buffer: an async
    /// method may not hold a pointer.
    /// </summary>
    /// <param name="buffer">The receive buffer (pinned).</param>
    /// <param name="n">Bytes received.</param>
    /// <returns>Calls completed, a negative errno once the connection failed, or int.MinValue when the client is disposed.</returns>
    private unsafe int Input(byte[] buffer, int n)
    {
        lock (_sync)
        {
            if (_client == 0)
            {
                return int.MinValue;
            }

            int rc;
            fixed (byte* p = buffer)
            {
                rc = Native.ClientInput(_client, p, (nuint)n);
            }

            FlushLocked(); // a protocol error's GOAWAY leaves too
            return rc;
        }
    }

    /// <summary>Sends the queued output, coalescing whatever is waiting into one send.</summary>
    /// <returns>A task that ends when the output channel completes or the socket fails.</returns>
    private async Task SendLoopAsync()
    {
        ChannelReader<byte[]> reader = _output.Reader;
        var batch = new List<byte[]>();
        try
        {
            while (await reader.WaitToReadAsync().ConfigureAwait(false))
            {
                while (reader.TryRead(out byte[]? bytes))
                {
                    batch.Add(bytes);
                }

                if (batch.Count == 1)
                {
                    await SendAllAsync(batch[0]).ConfigureAwait(false);
                }
                else
                {
                    int total = 0;
                    foreach (byte[] b in batch)
                    {
                        total += b.Length;
                    }

                    byte[] rented = ArrayPool<byte>.Shared.Rent(total);
                    int at = 0;
                    foreach (byte[] b in batch)
                    {
                        b.CopyTo(rented, at);
                        at += b.Length;
                    }

                    await SendAllAsync(rented.AsMemory(0, total)).ConfigureAwait(false);
                    ArrayPool<byte>.Shared.Return(rented);
                }

                batch.Clear();
            }
        }
        catch (Exception e) when (e is SocketException or ObjectDisposedException)
        {
            Teardown($"connection lost ({(e as SocketException)?.SocketErrorCode.ToString() ?? "closed"})");
        }
    }

    /// <summary>Sends every byte (a stream socket may take a send in parts).</summary>
    /// <param name="bytes">The bytes.</param>
    /// <returns>A task that completes once all are sent.</returns>
    /// <exception cref="SocketException">The connection failed.</exception>
    /// <exception cref="ObjectDisposedException">The socket was closed.</exception>
    private async Task SendAllAsync(ReadOnlyMemory<byte> bytes)
    {
        while (!bytes.IsEmpty)
        {
            int sent = await _socket.SendAsync(bytes, SocketFlags.None).ConfigureAwait(false);
            bytes = bytes[sent..];
        }
    }

    /// <summary>
    /// Ends the client once: frees the native client (its callbacks complete every call), stops
    /// the sender, closes the socket.
    /// </summary>
    /// <param name="lost">Why the connection ended (calls fail UNAVAILABLE with it), or null for a dispose (CANCELLED).</param>
    private void Teardown(string? lost)
    {
        lock (_sync)
        {
            if (_client == 0)
            {
                return;
            }

            _lostReason = lost;
            Native.ClientFree(_client); // completes every call through OnDone
            _client = 0;
        }

        _output.Writer.TryComplete();
        try
        {
            _socket.Shutdown(SocketShutdown.Both);
        }
        catch (SocketException)
        {
            // already gone
        }

        _socket.Dispose();
    }

    /// <summary>Maps a refused call (the C ABI's negative result) to the exception its Task carries.</summary>
    /// <param name="rc">The result.</param>
    /// <returns>The exception.</returns>
    private RpcException RefusalOf(int rc) => rc switch
    {
        -Native.ESHUTDOWN => new RpcException(new Status(StatusCode.Unavailable,
            "the connection takes no new calls (GOAWAY, or out of stream ids): open a new client")),
        -Native.EMSGSIZE => new RpcException(new Status(StatusCode.ResourceExhausted, "request of 4 GiB or more")),
        -Native.EINVAL => new RpcException(new Status(StatusCode.InvalidArgument, "unknown method handle")),
        _ => new RpcException(new Status(StatusCode.Unavailable, _lostReason ?? $"call refused ({rc})")),
    };

    /// <summary>
    /// The native client's done callback for every call: resolves the call's Task.
    /// </summary>
    /// <param name="context">The call's GCHandle.</param>
    /// <param name="status">The gRPC status.</param>
    /// <param name="message">The status message (UTF-8), or null.</param>
    /// <param name="messageLength">Its length.</param>
    /// <param name="response">The response message (status 0), or null.</param>
    /// <param name="responseLength">Its length.</param>
    /// <remarks>
    /// Runs under the client's lock, inside the native client: it copies what it needs (the
    /// pointers die with the callback) and resolves the Task, whose continuations run
    /// asynchronously, so no user code runs here. Calls completed while the connection is being
    /// torn down after a loss (the native client reports CANCELLED "client closed") fail
    /// UNAVAILABLE with the reason instead.
    /// </remarks>
    [UnmanagedCallersOnly]
    private static unsafe void OnDone(nint context, int status, byte* message, nuint messageLength, byte* response,
        nuint responseLength)
    {
        GCHandle handle = GCHandle.FromIntPtr(context);
        var pending = (PendingCall)handle.Target!;
        handle.Free();
        if (status == 0)
        {
            pending.Complete(new ReadOnlySpan<byte>(response, checked((int)responseLength)).ToArray());
            return;
        }

        string? lost = pending.Owner._lostReason;
        StatusCode code = (StatusCode)status;
        string detail = messageLength == 0 ? "" : Encoding.UTF8.GetString(message, checked((int)messageLength));
        if (lost is not null && code == StatusCode.Cancelled)
        {
            code = StatusCode.Unavailable;
            detail = lost;
        }

        pending.Fail(new RpcException(new Status(code, detail)));
    }

    /// <summary>One call in flight: its Task, and the client that issued it.</summary>
    /// <param name="owner">The client.</param>
    private sealed class PendingCall(GrpcAsmClient owner)
    {
        /// <summary>Resolved by <see cref="OnDone"/>; continuations run asynchronously (never under the client's lock).</summary>
        private readonly TaskCompletionSource<byte[]> _completion = new(TaskCreationOptions.RunContinuationsAsynchronously);

        /// <summary>The client that issued the call.</summary>
        public GrpcAsmClient Owner { get; } = owner;

        /// <summary>The call's Task.</summary>
        public Task<byte[]> Task => _completion.Task;

        /// <summary>Resolves the call with its response.</summary>
        /// <param name="response">The response message.</param>
        public void Complete(byte[] response) => _completion.TrySetResult(response);

        /// <summary>Fails the call.</summary>
        /// <param name="error">The error.</param>
        public void Fail(RpcException error) => _completion.TrySetException(error);
    }
}
