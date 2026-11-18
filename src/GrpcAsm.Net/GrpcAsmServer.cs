using System.Buffers;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using Google.Protobuf;
using Grpc.Core;

namespace GrpcAsm.Net;

/// <summary>Options of a <see cref="GrpcAsmServer"/>. Zero (or null) means the engine's default.</summary>
public sealed class GrpcAsmServerOptions
{
    /// <summary>TCP port, 1..65535. Default 50051; every worker binds it (SO_REUSEPORT).</summary>
    public int Port { get; set; } = 50051;

    /// <summary>Worker threads (event loops), 1..256. Default 1. Handlers run on these threads.</summary>
    public int Workers { get; set; } = 1;

    /// <summary>Concurrent calls per connection (SETTINGS_MAX_CONCURRENT_STREAMS), 1..1000; 0: 100.</summary>
    public int MaxConcurrentStreams { get; set; }

    /// <summary>Connections per worker, 1..1,000,000; 0: 10,000.</summary>
    public int MaxConnectionsPerWorker { get; set; }

    /// <summary>
    /// Time without traffic before a connection closes: null for the default (300 s),
    /// <see cref="Timeout.InfiniteTimeSpan"/> for never.
    /// </summary>
    public TimeSpan? IdleTimeout { get; set; }

    /// <summary>How long a stopping server lets calls in flight finish, 1..3600 s; zero: 10 s.</summary>
    public TimeSpan ShutdownGrace { get; set; }

    /// <summary>Request bytes one connection may buffer, in MiB, 1..4096; 0: 64.</summary>
    public int ConnectionBufferMegabytes { get; set; }

    /// <summary>Largest request message accepted, bytes; 0: 4 MiB. Larger is RESOURCE_EXHAUSTED.</summary>
    public int MaxMessageBytes { get; set; }
}

/// <summary>What a stopped server counted, summed over its workers.</summary>
/// <param name="Connections">Connections accepted.</param>
/// <param name="Requests">Calls handled.</param>
/// <param name="Errors">Calls answered with an error status.</param>
public readonly record struct GrpcAsmServerTotals(ulong Connections, ulong Requests, ulong Errors);

/// <summary>
/// A raw unary handler: the request message's bytes, and the call to answer.
/// </summary>
/// <param name="request">
/// The request message (protobuf, after the gRPC framing). Valid only until the handler returns:
/// it may point into the engine's receive buffer.
/// </param>
/// <param name="call">The call: answer it once, with <see cref="GrpcAsmCall.Reply"/> or <see cref="GrpcAsmCall.Fail"/>.</param>
/// <remarks>
/// Runs inline on one of the server's worker threads, which serves all of its connections:
/// a handler that blocks stalls every call of that worker. A handler that returns without
/// answering gets INTERNAL "handler returned without a reply". An exception is answered too
/// (see <see cref="GrpcAsmServer"/>), never propagated into the engine.
/// </remarks>
public delegate void RawUnaryHandler(ReadOnlySpan<byte> request, GrpcAsmCall call);

/// <summary>
/// One call, valid only while its handler runs: a <c>ref struct</c>, so it cannot be stored or
/// captured beyond it (the engine frees the call when the handler returns).
/// </summary>
public readonly unsafe ref struct GrpcAsmCall
{
    /// <summary>The C ABI's <c>grpcasm_call*</c>.</summary>
    private readonly nint _handle;

    /// <summary>Wraps a native call handle.</summary>
    /// <param name="handle">The <c>grpcasm_call*</c> the engine passed to the handler.</param>
    internal GrpcAsmCall(nint handle) => _handle = handle;

    /// <summary>Answers the call with one message and status OK.</summary>
    /// <param name="message">The response message (protobuf bytes, without gRPC framing); copied before this returns.</param>
    /// <exception cref="InvalidOperationException">The call was answered already.</exception>
    /// <exception cref="ArgumentOutOfRangeException">The message is 4 GiB or more.</exception>
    /// <exception cref="OutOfMemoryException">
    /// The engine could not queue the answer. The server's dispatcher then ends the connection,
    /// as the C ABI requires: let it propagate.
    /// </exception>
    public void Reply(ReadOnlySpan<byte> message)
    {
        int rc;
        fixed (byte* p = message)
        {
            rc = Native.CallReply(_handle, p, (nuint)message.Length);
        }

        Check(rc);
    }

    /// <summary>Answers the call with an error status (a Trailers-Only response).</summary>
    /// <param name="status">The status: anything but <see cref="StatusCode.OK"/> (that is <see cref="Reply"/>'s).</param>
    /// <param name="message">
    /// The status message, or null. The engine percent-encodes what gRPC requires and sends at
    /// most 1,024 bytes of its UTF-8.
    /// </param>
    /// <exception cref="InvalidOperationException">The call was answered already.</exception>
    /// <exception cref="ArgumentOutOfRangeException">The status is OK or above 16.</exception>
    /// <exception cref="OutOfMemoryException">The engine could not queue the answer (see <see cref="Reply"/>).</exception>
    public void Fail(StatusCode status, string? message = null)
    {
        if (message is null)
        {
            Check(Native.CallFail(_handle, (int)status, null));
            return;
        }

        // NUL-terminated UTF-8: on the stack when it is short (the usual case), rented
        // otherwise. The engine reads at most 1,024 bytes of it, but all of it is encoded so
        // a multi-byte character is never cut here (the engine cuts at its own limit).
        int max = Encoding.UTF8.GetMaxByteCount(message.Length) + 1;
        byte[]? rented = max > 512 ? ArrayPool<byte>.Shared.Rent(max) : null;
        Span<byte> buffer = rented ?? stackalloc byte[max];
        try
        {
            int n = Encoding.UTF8.GetBytes(message, buffer);
            buffer[n] = 0;
            int rc;
            fixed (byte* p = buffer)
            {
                rc = Native.CallFail(_handle, (int)status, p);
            }

            Check(rc);
        }
        finally
        {
            if (rented is not null)
            {
                ArrayPool<byte>.Shared.Return(rented);
            }
        }
    }

    /// <summary>Turns a call function's result into the documented exceptions.</summary>
    /// <param name="rc">0, or the C ABI's negative result.</param>
    /// <exception cref="InvalidOperationException">-EALREADY.</exception>
    /// <exception cref="ArgumentOutOfRangeException">-EINVAL or -EMSGSIZE.</exception>
    /// <exception cref="OutOfMemoryException">-1: out of memory.</exception>
    private static void Check(int rc)
    {
        switch (rc)
        {
            case 0:
                return;
            case -Native.EALREADY:
                throw new InvalidOperationException("the call has been answered already");
            case -Native.EINVAL:
                throw new ArgumentOutOfRangeException("status", "a failed call's status is 1..16 (OK is Reply's)");
            case -Native.EMSGSIZE:
                throw new ArgumentOutOfRangeException("message", "a gRPC message is below 4 GiB");
            default:
                throw new OutOfMemoryException("the engine could not queue the answer");
        }
    }
}

/// <summary>
/// A gRPC server whose HTTP/2, HPACK, gRPC call layer and event loops are GrpcAsm's assembly
/// engine; its methods are .NET handlers, called inline on the engine's worker threads.
/// </summary>
/// <remarks>
/// <para>
/// Lifecycle: create, register methods (<see cref="AddUnary(string, RawUnaryHandler)"/>,
/// <see cref="AddUnary{TRequest, TResponse}(string, Func{TRequest, TResponse})"/>),
/// <see cref="Start"/>, then <see cref="Stop"/> (or <see cref="Dispose"/>). The engine also
/// answers, without any handler: the gRPC health service (SERVING for every service that has a
/// method), UNIMPLEMENTED, the HTTP-level refusals and RESOURCE_EXHAUSTED above
/// <see cref="GrpcAsmServerOptions.MaxMessageBytes"/>.
/// </para>
/// <para>
/// Handlers run inline, on the worker thread that read the request, through an
/// <see cref="System.Runtime.InteropServices.UnmanagedCallersOnlyAttribute"/> entry point:
/// no queue, no thread switch, no allocation by this class. The C ABI requires the answer
/// before the handler returns, so a handler cannot hand its call to another thread (running
/// handlers on the thread pool would need an asynchronous answer in the C ABI first). An
/// exception thrown by a handler is answered: an <see cref="RpcException"/> with its status and
/// detail, anything else INTERNAL "Exception was thrown by handler." (grpc-dotnet's text). The
/// worker carries on.
/// </para>
/// <para>
/// Footgun: one started server per process (the engine binds its hooks at link time);
/// <see cref="Start"/> on a second one throws until the first is stopped.
/// </para>
/// </remarks>
public sealed unsafe class GrpcAsmServer : IDisposable
{
    /// <summary>The C ABI's <c>grpcasm_server*</c>; 0 once disposed.</summary>
    private nint _server;

    /// <summary>One GCHandle per registered handler: the native context of its method.</summary>
    private readonly List<GCHandle> _handlers = [];

    /// <summary>True between a successful <see cref="Start"/> and <see cref="Stop"/>.</summary>
    private bool _started;

    /// <summary>Creates a server (not started).</summary>
    /// <param name="options">Options, or null for every default.</param>
    /// <exception cref="ArgumentOutOfRangeException">An option is out of range.</exception>
    /// <exception cref="OutOfMemoryException">The engine could not allocate the server.</exception>
    /// <exception cref="DllNotFoundException">libgrpcasm.so cannot be loaded (not Linux x64, or not deployed).</exception>
    /// <exception cref="BadImageFormatException">The loaded libgrpcasm.so has another ABI version.</exception>
    public GrpcAsmServer(GrpcAsmServerOptions? options = null)
    {
        // First: every struct below is laid out for one ABI version (see the method).
        Native.RequireCompatibleLibrary();
        options ??= new GrpcAsmServerOptions();
        var native = new ServerOptions
        {
            Size = (uint)sizeof(ServerOptions),
            Port = checked((uint)options.Port),
            Workers = checked((uint)options.Workers),
            MaxStreams = checked((uint)options.MaxConcurrentStreams),
            MaxConnections = checked((uint)options.MaxConnectionsPerWorker),
            IdleTimeoutSeconds = options.IdleTimeout switch
            {
                null => 0,
                { } t when t == Timeout.InfiniteTimeSpan => uint.MaxValue,
                { } t => checked((uint)Math.Max(1, t.TotalSeconds)),
            },
            ShutdownGraceSeconds = checked((uint)options.ShutdownGrace.TotalSeconds),
            ConnectionBufferMb = checked((uint)options.ConnectionBufferMegabytes),
            MaxMessageBytes = checked((uint)options.MaxMessageBytes),
        };
        nint server;
        int rc = Native.ServerNew(&native, &server);
        if (rc == -Native.EINVAL)
        {
            throw new ArgumentOutOfRangeException(nameof(options), "an option is out of range (see GrpcAsmServerOptions)");
        }

        if (rc != 0)
        {
            throw new OutOfMemoryException("grpcasm_server_new failed");
        }

        _server = server;
    }

    /// <summary>Registers a unary method with a raw handler, before <see cref="Start"/>.</summary>
    /// <param name="path">The method's full path, "/package.Service/Method" (3..255 bytes).</param>
    /// <param name="handler">The handler (see <see cref="RawUnaryHandler"/>).</param>
    /// <exception cref="ArgumentNullException">The path or the handler is null.</exception>
    /// <exception cref="ArgumentException">The path is malformed, already registered, or one too many (62).</exception>
    /// <exception cref="InvalidOperationException">The server has started.</exception>
    /// <exception cref="ObjectDisposedException">The server is disposed.</exception>
    public void AddUnary(string path, RawUnaryHandler handler)
    {
        ArgumentNullException.ThrowIfNull(path);
        ArgumentNullException.ThrowIfNull(handler);
        ThrowIfUnusable();
        if (_started)
        {
            throw new InvalidOperationException("methods are registered before the server starts");
        }

        byte[] utf8 = Encoding.UTF8.GetBytes(path + "\0");
        GCHandle context = GCHandle.Alloc(handler);
        int rc;
        fixed (byte* p = utf8)
        {
            rc = Native.ServerAddUnary(_server, p, &Dispatch, GCHandle.ToIntPtr(context));
        }

        if (rc != 0)
        {
            context.Free();
            throw rc switch
            {
                -Native.EBUSY => new InvalidOperationException("methods are registered before the server starts"),
                -17 => new ArgumentException($"{path} is registered already", nameof(path)), // EEXIST
                -28 => new ArgumentException("62 methods already", nameof(path)), // ENOSPC
                _ => new ArgumentException($"malformed path: {path}", nameof(path)),
            };
        }

        _handlers.Add(context);
    }

    /// <summary>
    /// Registers a unary method with a typed handler: the request is parsed and the response
    /// serialized with Google.Protobuf.
    /// </summary>
    /// <typeparam name="TRequest">The request message type.</typeparam>
    /// <typeparam name="TResponse">The response message type.</typeparam>
    /// <param name="path">The method's full path, "/package.Service/Method".</param>
    /// <param name="handler">Maps a request to its response; throw <see cref="RpcException"/> for an error status.</param>
    /// <exception cref="ArgumentNullException">The path or the handler is null.</exception>
    /// <exception cref="ArgumentException">The path is malformed, already registered, or one too many.</exception>
    /// <exception cref="InvalidOperationException">The server has started.</exception>
    /// <exception cref="ObjectDisposedException">The server is disposed.</exception>
    /// <remarks>
    /// A request that is not a well-formed <typeparamref name="TRequest"/> is answered
    /// INVALID_ARGUMENT "malformed request message", as the engine's own services answer it.
    /// A response of up to 1 KiB is serialized on the stack, a larger one into a rented
    /// buffer: either way the engine copies it once, straight into its output.
    /// </remarks>
    public void AddUnary<TRequest, TResponse>(string path, Func<TRequest, TResponse> handler)
        where TRequest : IMessage<TRequest>, new()
        where TResponse : IMessage<TResponse>
    {
        ArgumentNullException.ThrowIfNull(handler);
        var parser = new MessageParser<TRequest>(() => new TRequest());
        AddUnary(path, (request, call) =>
        {
            TRequest message;
            try
            {
                message = parser.ParseFrom(request);
            }
            catch (InvalidProtocolBufferException)
            {
                call.Fail(StatusCode.InvalidArgument, "malformed request message");
                return;
            }

            TResponse response = handler(message);
            int size = response.CalculateSize();
            if (size <= 1024)
            {
                Span<byte> buffer = stackalloc byte[size];
                response.WriteTo(buffer);
                call.Reply(buffer);
                return;
            }

            byte[] rented = ArrayPool<byte>.Shared.Rent(size);
            try
            {
                Span<byte> buffer = rented.AsSpan(0, size);
                response.WriteTo(buffer);
                call.Reply(buffer);
            }
            finally
            {
                ArrayPool<byte>.Shared.Return(rented);
            }
        });
    }

    /// <summary>Starts the server: every worker binds the port and serves until <see cref="Stop"/>.</summary>
    /// <exception cref="InvalidOperationException">This server started already, or another one runs in this process.</exception>
    /// <exception cref="ObjectDisposedException">The server is disposed.</exception>
    /// <exception cref="SocketException">Another process serves the port (EADDRINUSE).</exception>
    /// <exception cref="IOException">A worker could not start (the engine logged why; nothing is left running).</exception>
    /// <remarks>
    /// The workers inherit the calling thread's signal mask; the engine never touches signals,
    /// so the .NET runtime keeps handling them. Logs "listening" (stderr) on success.
    /// </remarks>
    public void Start()
    {
        ThrowIfUnusable();
        int rc = Native.ServerStart(_server);
        switch (rc)
        {
            case 0:
                _started = true;
                return;
            case -Native.EBUSY:
                throw new InvalidOperationException("this server started already, or another GrpcAsmServer runs in this process");
            case -Native.EADDRINUSE:
                throw new SocketException((int)SocketError.AddressAlreadyInUse);
            default:
                throw new IOException($"the server could not start (grpcasm_server_start: {rc})");
        }
    }

    /// <summary>
    /// Stops a started server: no new connections, GOAWAY to the open ones, calls in flight
    /// finish (within <see cref="GrpcAsmServerOptions.ShutdownGrace"/>), then the workers exit.
    /// </summary>
    /// <returns>What the server counted.</returns>
    /// <exception cref="InvalidOperationException">The server is not running.</exception>
    /// <exception cref="ObjectDisposedException">The server is disposed.</exception>
    /// <remarks>Footgun: never from a handler (a worker would wait for itself).</remarks>
    public GrpcAsmServerTotals Stop()
    {
        ThrowIfUnusable();
        if (!_started)
        {
            throw new InvalidOperationException("the server is not running");
        }

        ulong* totals = stackalloc ulong[3];
        Native.ServerStop(_server, totals);
        _started = false;
        return new GrpcAsmServerTotals(totals[0], totals[1], totals[2]);
    }

    /// <summary>Stops the server if it runs, frees it, and releases the handlers.</summary>
    public void Dispose()
    {
        if (_server == 0)
        {
            return;
        }

        // grpcasm_server_free stops a running server first: after it no handler can run, so
        // the GCHandles the workers dereference can be freed.
        Native.ServerFree(_server);
        _server = 0;
        _started = false;
        foreach (GCHandle handle in _handlers)
        {
            handle.Free();
        }

        _handlers.Clear();
    }

    /// <summary>Throws when the server is disposed.</summary>
    /// <exception cref="ObjectDisposedException">It is.</exception>
    private void ThrowIfUnusable() => ObjectDisposedException.ThrowIf(_server == 0, this);

    /// <summary>
    /// The engine's entry point for every method: finds the handler and runs it inline.
    /// </summary>
    /// <param name="context">The handler's GCHandle (registered with the method).</param>
    /// <param name="call">The <c>grpcasm_call*</c>.</param>
    /// <param name="request">The request message.</param>
    /// <param name="length">Its length.</param>
    /// <returns>0, or -1 to end the connection (the answer could not be queued).</returns>
    /// <remarks>
    /// Nothing may escape into the engine: an exception unwinding through assembly frames would
    /// corrupt the worker. So every exception is answered here — an <see cref="RpcException"/>
    /// with its status, anything else INTERNAL — and only an out-of-memory answer (the engine's
    /// own failure) ends the connection, as the C ABI's contract says.
    /// </remarks>
    [UnmanagedCallersOnly]
    private static int Dispatch(nint context, nint call, byte* request, nuint length)
    {
        var answer = new GrpcAsmCall(call);
        try
        {
            var handler = (RawUnaryHandler)GCHandle.FromIntPtr(context).Target!;
            handler(new ReadOnlySpan<byte>(request, checked((int)length)), answer);
            return 0;
        }
        catch (OutOfMemoryException)
        {
            return -1;
        }
        catch (RpcException e)
        {
            return TryFail(answer, e.StatusCode == StatusCode.OK ? StatusCode.Unknown : e.StatusCode, e.Status.Detail);
        }
        catch (Exception)
        {
            return TryFail(answer, StatusCode.Internal, "Exception was thrown by handler.");
        }
    }

    /// <summary>Answers a call whose handler threw, unless it answered before throwing.</summary>
    /// <param name="call">The call.</param>
    /// <param name="status">The status to send.</param>
    /// <param name="message">Its message.</param>
    /// <returns>0, or -1 when the answer could not be queued.</returns>
    private static int TryFail(GrpcAsmCall call, StatusCode status, string? message)
    {
        try
        {
            call.Fail(status, message);
            return 0;
        }
        catch (InvalidOperationException)
        {
            return 0; // answered before the exception: that answer stands
        }
        catch (OutOfMemoryException)
        {
            return -1;
        }
    }
}
