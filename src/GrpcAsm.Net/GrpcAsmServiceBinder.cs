using System.Buffers;
using Grpc.Core;

namespace GrpcAsm.Net;

/// <summary>
/// Hosts grpc-dotnet service classes on a <see cref="GrpcAsmServer"/>: the
/// <see cref="ServiceBinderBase"/> that the <c>BindService</c> method Grpc.Tools generates for
/// every service registers its methods with. The same class ASP.NET Core hosts with
/// <c>MapGrpcService&lt;T&gt;()</c> runs on GrpcAsm's assembly engine with one line:
/// <code>Greeter.BindService(server.ServiceBinder, new GreeterService());</code>
/// </summary>
/// <remarks>
/// <para>
/// No reflection: the generated method calls <see cref="AddMethod{TRequest, TResponse}(Method{TRequest, TResponse}, UnaryServerMethod{TRequest, TResponse})"/>
/// once per method, so binding is trimming- and NativeAOT-safe. Each unary method becomes an
/// <see cref="GrpcAsmServer.AddUnary(string, RawUnaryHandler)"/> registration under its full
/// name; the request and the response go through the method's own marshallers (as grpc-dotnet
/// does), with a <see cref="ServerCallContext"/> per call.
/// </para>
/// <para>What differs from ASP.NET Core, today:</para>
/// <list type="bullet">
/// <item>Unary methods only. Binding a service with a streaming method throws
/// <see cref="NotSupportedException"/> naming it, before anything runs: GrpcAsm's C ABI has no
/// streaming calls yet.</item>
/// <item>The handler's <see cref="Task"/> must be complete when it returns: the engine runs it
/// inline on the worker thread that read the request and needs the answer before the handler
/// returns. <c>Task.FromResult</c>, or an <c>async</c> method that never really awaits, is fine;
/// a task still running is answered UNIMPLEMENTED (and left to finish, its result unused).</item>
/// <item>The context is partial: no request headers, deadline, peer or host reach handlers
/// through the C ABI (empty or <see cref="DateTime.MaxValue"/>), the cancellation token never
/// fires, and custom response headers or trailers are refused (UNIMPLEMENTED) rather than
/// silently dropped. See <see cref="GrpcAsmServerCallContext"/>.</item>
/// <item>No interceptors.</item>
/// </list>
/// <para>
/// Errors are answered as grpc-dotnet answers them, so a client sees the same statuses from both
/// servers (tests/GrpcAsm.Net.Tests checks it against Kestrel): an <see cref="RpcException"/>
/// with its status, any other exception UNKNOWN "Exception was thrown by handler.", a null
/// response CANCELLED "No message returned from method.", and a non-OK
/// <see cref="ServerCallContext.Status"/> set by the handler as that status. A request the
/// method's marshaller cannot read is UNKNOWN too, as from ASP.NET Core (measured), where
/// GrpcAsm's own typed and raw handlers answer INVALID_ARGUMENT "malformed request message".
/// </para>
/// </remarks>
public sealed class GrpcAsmServiceBinder : ServiceBinderBase
{
    /// <summary>The server the methods are registered on.</summary>
    private readonly GrpcAsmServer _server;

    /// <summary>Creates the binder of <paramref name="server"/> (see <see cref="GrpcAsmServer.ServiceBinder"/>).</summary>
    /// <param name="server">The server.</param>
    internal GrpcAsmServiceBinder(GrpcAsmServer server) => _server = server;

    /// <summary>Registers a unary method under its full name ("/package.Service/Method").</summary>
    /// <typeparam name="TRequest">The request type.</typeparam>
    /// <typeparam name="TResponse">The response type.</typeparam>
    /// <param name="method">The method's descriptor: its name and marshallers.</param>
    /// <param name="handler">The service's method.</param>
    /// <exception cref="ArgumentNullException">The method or the handler is null (a service bound without an instance).</exception>
    /// <exception cref="ArgumentException">The name is malformed, already registered, or one too many (62).</exception>
    /// <exception cref="InvalidOperationException">The server has started.</exception>
    /// <exception cref="ObjectDisposedException">The server is disposed.</exception>
    public override void AddMethod<TRequest, TResponse>(Method<TRequest, TResponse> method, UnaryServerMethod<TRequest, TResponse>? handler)
    {
        ArgumentNullException.ThrowIfNull(method);
        ArgumentNullException.ThrowIfNull(handler);
        var unary = new UnaryServiceMethod<TRequest, TResponse>(method, handler);
        _server.AddUnary(method.FullName, unary.Invoke);
    }

    /// <summary>Refuses a client-streaming method: the C ABI has no streaming calls yet.</summary>
    /// <typeparam name="TRequest">The request type.</typeparam>
    /// <typeparam name="TResponse">The response type.</typeparam>
    /// <param name="method">The method.</param>
    /// <param name="handler">The service's method (unused).</param>
    /// <exception cref="NotSupportedException">Always, naming the method.</exception>
    public override void AddMethod<TRequest, TResponse>(Method<TRequest, TResponse> method, ClientStreamingServerMethod<TRequest, TResponse>? handler) =>
        throw Unsupported(method);

    /// <summary>Refuses a server-streaming method: the C ABI has no streaming calls yet.</summary>
    /// <typeparam name="TRequest">The request type.</typeparam>
    /// <typeparam name="TResponse">The response type.</typeparam>
    /// <param name="method">The method.</param>
    /// <param name="handler">The service's method (unused).</param>
    /// <exception cref="NotSupportedException">Always, naming the method.</exception>
    public override void AddMethod<TRequest, TResponse>(Method<TRequest, TResponse> method, ServerStreamingServerMethod<TRequest, TResponse>? handler) =>
        throw Unsupported(method);

    /// <summary>Refuses a bidirectional-streaming method: the C ABI has no streaming calls yet.</summary>
    /// <typeparam name="TRequest">The request type.</typeparam>
    /// <typeparam name="TResponse">The response type.</typeparam>
    /// <param name="method">The method.</param>
    /// <param name="handler">The service's method (unused).</param>
    /// <exception cref="NotSupportedException">Always, naming the method.</exception>
    public override void AddMethod<TRequest, TResponse>(Method<TRequest, TResponse> method, DuplexStreamingServerMethod<TRequest, TResponse>? handler) =>
        throw Unsupported(method);

    /// <summary>The refusal of a streaming method.</summary>
    /// <param name="method">The method.</param>
    /// <returns>The exception to throw.</returns>
    private static NotSupportedException Unsupported(IMethod method) =>
        new($"{method.FullName} is a {method.Type} method: GrpcAsm hosts unary methods only (its C ABI has no streaming calls yet).");
}

/// <summary>
/// One bound unary method: deserializes the request with the method's marshaller, calls the
/// service, and answers with the serialized response or the status grpc-dotnet would send.
/// </summary>
/// <typeparam name="TRequest">The request type.</typeparam>
/// <typeparam name="TResponse">The response type.</typeparam>
internal sealed class UnaryServiceMethod<TRequest, TResponse>
    where TRequest : class
    where TResponse : class
{
    /// <summary>The method's descriptor.</summary>
    private readonly Method<TRequest, TResponse> _method;

    /// <summary>The service's method.</summary>
    private readonly UnaryServerMethod<TRequest, TResponse> _handler;

    /// <summary>The detail sent when the handler's task had not completed (built once).</summary>
    private readonly string _pendingDetail;

    /// <summary>Binds <paramref name="handler"/> to <paramref name="method"/>.</summary>
    /// <param name="method">The method's descriptor.</param>
    /// <param name="handler">The service's method.</param>
    public UnaryServiceMethod(Method<TRequest, TResponse> method, UnaryServerMethod<TRequest, TResponse> handler)
    {
        _method = method;
        _handler = handler;
        _pendingDetail = $"{method.FullName} returned a Task that had not completed: GrpcAsm runs handlers inline and " +
                         "needs the answer before the handler returns (asynchronous handlers are not supported yet).";
    }

    /// <summary>The <see cref="RawUnaryHandler"/> registered for the method: one call, answered once.</summary>
    /// <param name="request">The request message's bytes (valid during this call).</param>
    /// <param name="call">The call.</param>
    /// <remarks>
    /// <para>
    /// Every outcome is answered here, so the server's dispatcher only sees an
    /// <see cref="OutOfMemoryException"/>: the engine's failure to queue an answer, which ends the
    /// connection as the C ABI requires. Statuses follow grpc-dotnet's server (see
    /// <see cref="GrpcAsmServiceBinder"/>); a request the marshaller cannot read is answered as
    /// grpc-dotnet answers a throwing deserializer.
    /// </para>
    /// <para>
    /// The order of checks after the handler mirrors grpc-dotnet's unary call handler: a null
    /// response, then the status the handler set, then (GrpcAsm's own refusal) trailers it cannot
    /// send, then the response.
    /// </para>
    /// </remarks>
    public void Invoke(ReadOnlySpan<byte> request, GrpcAsmCall call)
    {
        CallBuffers buffers = CallBuffers.Current;
        TRequest message;
        try
        {
            message = buffers.Deserialize(request, _method.RequestMarshaller.ContextualDeserializer);
        }
        catch (Exception e) when (e is not OutOfMemoryException)
        {
            FailLikeGrpcDotnet(call, e);
            return;
        }

        var context = new GrpcAsmServerCallContext(_method.FullName);
        TResponse? response;
        try
        {
            Task<TResponse> task = _handler(message, context);
            if (!task.IsCompleted)
            {
                // The engine needs the answer now; the task runs on, and its fault (if any) is
                // observed so that it does not surface as an UnobservedTaskException.
                ObserveFault(task);
                call.Fail(StatusCode.Unimplemented, _pendingDetail);
                return;
            }

            // GetResult rethrows a faulted task's own exception (not an AggregateException), as
            // await does: the same exception grpc-dotnet would catch.
            response = task.GetAwaiter().GetResult();
        }
        catch (Exception e) when (e is not OutOfMemoryException)
        {
            FailLikeGrpcDotnet(call, e);
            return;
        }

        if (response is null)
        {
            call.Fail(StatusCode.Cancelled, "No message returned from method.");
            return;
        }

        if (context.Status.StatusCode != StatusCode.OK)
        {
            // grpc-dotnet writes the message, then this status in the trailers; a client sees
            // the status either way (it discards a message that ends in an error).
            call.Fail(context.Status.StatusCode, context.Status.Detail);
            return;
        }

        if (context.HasResponseTrailers)
        {
            call.Fail(StatusCode.Unimplemented, GrpcAsmServerCallContext.TrailersRefused);
            return;
        }

        ReadOnlySpan<byte> payload;
        try
        {
            payload = buffers.Serialize(response, _method.ResponseMarshaller.ContextualSerializer);
        }
        catch (Exception e) when (e is not OutOfMemoryException)
        {
            FailLikeGrpcDotnet(call, e);
            return;
        }

        call.Reply(payload);
    }

    /// <summary>Answers an exception the way grpc-dotnet's server does.</summary>
    /// <param name="call">The call.</param>
    /// <param name="e">What the deserializer, the handler or the serializer threw.</param>
    private static void FailLikeGrpcDotnet(GrpcAsmCall call, Exception e)
    {
        if (e is RpcException rpc)
        {
            // An RpcException that claims OK is still an error: grpc-dotnet sends it as thrown,
            // and an OK status without a message would make the call look empty; UNKNOWN, as
            // the server's dispatcher answers it for raw handlers.
            call.Fail(rpc.StatusCode == StatusCode.OK ? StatusCode.Unknown : rpc.StatusCode, rpc.Status.Detail);
            return;
        }

        call.Fail(StatusCode.Unknown, "Exception was thrown by handler.");
    }

    /// <summary>Observes a task's fault once it ends, so that it never goes unobserved.</summary>
    /// <param name="task">The task.</param>
    private static void ObserveFault(Task task) =>
        task.ContinueWith(static t => _ = t.Exception, CancellationToken.None,
            TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
}

/// <summary>
/// The <see cref="ServerCallContext"/> of a call hosted through <see cref="GrpcAsmServiceBinder"/>:
/// what GrpcAsm's C ABI can tell a handler, and refusals for what it cannot do.
/// </summary>
/// <remarks>
/// <list type="bullet">
/// <item><see cref="ServerCallContext.Method"/>: the method's full name.</item>
/// <item><see cref="ServerCallContext.Host"/> and <see cref="ServerCallContext.Peer"/>: empty, and
/// <see cref="ServerCallContext.RequestHeaders"/>: no entries. The engine passes handlers the
/// message only.</item>
/// <item><see cref="ServerCallContext.Deadline"/>: <see cref="DateTime.MaxValue"/> (no deadline,
/// grpc-dotnet's value when the client sets none); the engine does not pass grpc-timeout on.</item>
/// <item><see cref="ServerCallContext.CancellationToken"/>: never cancelled. The handler runs to
/// completion on the worker before the engine reads anything else from the connection.</item>
/// <item><see cref="ServerCallContext.WriteResponseHeadersAsync"/>: throws an
/// <see cref="RpcException"/> UNIMPLEMENTED, so the call fails with that reason.</item>
/// <item><see cref="ServerCallContext.ResponseTrailers"/>: may be read; entries added to it make
/// the call fail UNIMPLEMENTED, since the engine cannot send them.</item>
/// <item><see cref="ServerCallContext.Status"/>: a non-OK value set by the handler is the call's
/// status. <see cref="ServerCallContext.WriteOptions"/>: kept, ignored.</item>
/// <item><see cref="ServerCallContext.AuthContext"/>: unauthenticated (no TLS in the engine).</item>
/// </list>
/// Footgun: valid only while the handler runs, as in grpc-dotnet; a handler must not keep it.
/// </remarks>
internal sealed class GrpcAsmServerCallContext : ServerCallContext
{
    /// <summary>The refusal sent when a handler set response trailers.</summary>
    internal const string TrailersRefused = "GrpcAsm cannot send custom response trailers yet; ResponseTrailers must stay empty.";

    /// <summary>The refusal thrown by <see cref="WriteResponseHeadersAsyncCore"/>.</summary>
    private const string HeadersRefused = "GrpcAsm cannot send custom response headers yet.";

    /// <summary>The one unauthenticated context, shared: it holds no per-call state.</summary>
    private static readonly AuthContext Unauthenticated = new(null, new Dictionary<string, List<AuthProperty>>());

    /// <summary>The method's full name.</summary>
    private readonly string _method;

    /// <summary>Created when first read: most handlers never touch them.</summary>
    private Metadata? _requestHeaders;

    /// <summary>Created when first read; entries make the call fail (see the class remarks).</summary>
    private Metadata? _responseTrailers;

    /// <summary>The status the handler set (OK by default).</summary>
    private Status _status;

    /// <summary>Creates the context of one call.</summary>
    /// <param name="method">The method's full name.</param>
    public GrpcAsmServerCallContext(string method) => _method = method;

    /// <summary>True when the handler added response trailers (which the engine cannot send).</summary>
    public bool HasResponseTrailers => _responseTrailers is { Count: > 0 };

    /// <inheritdoc/>
    protected override string MethodCore => _method;

    /// <inheritdoc/>
    protected override string HostCore => string.Empty;

    /// <inheritdoc/>
    protected override string PeerCore => string.Empty;

    /// <inheritdoc/>
    protected override DateTime DeadlineCore => DateTime.MaxValue;

    /// <inheritdoc/>
    protected override Metadata RequestHeadersCore => _requestHeaders ??= new Metadata();

    /// <inheritdoc/>
    protected override CancellationToken CancellationTokenCore => CancellationToken.None;

    /// <inheritdoc/>
    protected override Metadata ResponseTrailersCore => _responseTrailers ??= new Metadata();

    /// <inheritdoc/>
    protected override Status StatusCore
    {
        get => _status;
        set => _status = value;
    }

    /// <inheritdoc/>
    protected override WriteOptions? WriteOptionsCore { get; set; }

    /// <inheritdoc/>
    protected override AuthContext AuthContextCore => Unauthenticated;

    /// <summary>Refuses: the engine sends no custom response headers.</summary>
    /// <param name="responseHeaders">The headers (unused).</param>
    /// <returns>Never returns.</returns>
    /// <exception cref="RpcException">Always: UNIMPLEMENTED, which becomes the call's status.</exception>
    protected override Task WriteResponseHeadersAsyncCore(Metadata responseHeaders) =>
        throw new RpcException(new Status(StatusCode.Unimplemented, HeadersRefused));

    /// <summary>Refuses: a GrpcAsm call has nothing to propagate (no deadline, no cancellation).</summary>
    /// <param name="options">The options (unused).</param>
    /// <returns>Never returns.</returns>
    /// <exception cref="NotSupportedException">Always.</exception>
    protected override ContextPropagationToken CreatePropagationTokenCore(ContextPropagationOptions? options) =>
        throw new NotSupportedException("GrpcAsm calls have no deadline or cancellation to propagate.");
}

/// <summary>
/// The per-thread buffers of bound calls: a <see cref="DeserializationContext"/> over the
/// request's bytes and a <see cref="SerializationContext"/> with a reusable buffer, so that the
/// marshallers run without a per-call allocation of their own.
/// </summary>
/// <remarks>
/// One per worker thread ([ThreadStatic]): a handler runs to completion on the worker that read
/// its request, so the deserialization (before the handler) and the serialization (after it) of
/// one call never overlap with another call's on the same thread.
/// </remarks>
internal sealed unsafe class CallBuffers
{
    /// <summary>A serialization buffer above this capacity is dropped after its call, so one large response does not pin memory on a worker for good.</summary>
    private const int KeepCapacity = 1 << 20;

    /// <summary>This thread's buffers.</summary>
    [ThreadStatic]
    private static CallBuffers? t_current;

    /// <summary>The request's bytes as <see cref="Memory{T}"/>, for <see cref="ReadOnlySequence{T}"/>.</summary>
    private readonly PointerMemory _request = new();

    /// <summary>The deserialization context over <see cref="_request"/>.</summary>
    private readonly RequestContext _requestContext;

    /// <summary>The serialization context.</summary>
    private readonly ResponseContext _responseContext = new();

    /// <summary>Creates a thread's buffers.</summary>
    private CallBuffers() => _requestContext = new RequestContext(_request);

    /// <summary>The calling thread's buffers, created on first use.</summary>
    public static CallBuffers Current => t_current ??= new CallBuffers();

    /// <summary>Runs a deserializer over a request's bytes.</summary>
    /// <typeparam name="T">The message type.</typeparam>
    /// <param name="payload">The bytes (the engine's receive buffer: native memory, valid during the call).</param>
    /// <param name="deserializer">The method's contextual deserializer.</param>
    /// <returns>The message.</returns>
    /// <remarks>
    /// The bytes are pinned for the deserializer's whole run (a no-op for native memory, which
    /// the GC never moves, but correct for any span). The deserializer must not keep the
    /// sequence beyond its return, as in grpc-dotnet, whose buffer is released after it too;
    /// Google.Protobuf copies what it keeps.
    /// </remarks>
    public T Deserialize<T>(ReadOnlySpan<byte> payload, Func<DeserializationContext, T> deserializer)
    {
        fixed (byte* p = payload)
        {
            _request.Reset(p, payload.Length);
            try
            {
                return deserializer(_requestContext);
            }
            finally
            {
                _request.Reset(null, 0);
            }
        }
    }

    /// <summary>Runs a serializer and returns what it produced.</summary>
    /// <typeparam name="T">The message type.</typeparam>
    /// <param name="message">The response.</param>
    /// <param name="serializer">The method's contextual serializer.</param>
    /// <returns>The serialized bytes, valid until this thread's next call.</returns>
    /// <exception cref="InvalidOperationException">The serializer returned without completing the payload.</exception>
    public ReadOnlySpan<byte> Serialize<T>(T message, Action<T, SerializationContext> serializer)
    {
        _responseContext.Reset(KeepCapacity);
        serializer(message, _responseContext);
        return _responseContext.Payload;
    }

    /// <summary>A <see cref="MemoryManager{T}"/> over a native pointer: the request's bytes as Memory, without a copy.</summary>
    private sealed class PointerMemory : MemoryManager<byte>
    {
        /// <summary>The bytes, or null between calls.</summary>
        private byte* _pointer;

        /// <summary>Their length.</summary>
        private int _length;

        /// <summary>Points the manager at a call's bytes (or at nothing).</summary>
        /// <param name="pointer">The bytes.</param>
        /// <param name="length">Their length.</param>
        public void Reset(byte* pointer, int length)
        {
            _pointer = pointer;
            _length = length;
        }

        /// <inheritdoc/>
        public override Span<byte> GetSpan() => new(_pointer, _length);

        /// <summary>Returns the pointer: the bytes are pinned already for the deserializer's run.</summary>
        /// <param name="elementIndex">The first byte.</param>
        /// <returns>A handle on the pointer.</returns>
        public override MemoryHandle Pin(int elementIndex = 0) => new(_pointer + elementIndex);

        /// <summary>Nothing to unpin.</summary>
        public override void Unpin()
        {
        }

        /// <summary>Owns nothing.</summary>
        /// <param name="disposing">Unused.</param>
        protected override void Dispose(bool disposing)
        {
        }
    }

    /// <summary>The <see cref="DeserializationContext"/> over the current request.</summary>
    /// <param name="request">The request's bytes.</param>
    private sealed class RequestContext(PointerMemory request) : DeserializationContext
    {
        /// <inheritdoc/>
        public override int PayloadLength => request.GetSpan().Length;

        /// <summary>A copy of the request (for marshallers that want an array).</summary>
        /// <returns>A new array.</returns>
        public override byte[] PayloadAsNewBuffer() => request.GetSpan().ToArray();

        /// <summary>The request as one segment, without a copy (Google.Protobuf's path).</summary>
        /// <returns>The sequence, valid during the deserializer's run.</returns>
        public override ReadOnlySequence<byte> PayloadAsReadOnlySequence() => new(request.Memory);
    }

    /// <summary>The <see cref="SerializationContext"/>: a reusable buffer writer, or a completed array.</summary>
    private sealed class ResponseContext : SerializationContext
    {
        /// <summary>The buffer Google.Protobuf writes into.</summary>
        private ArrayBufferWriter<byte> _writer = new(1024);

        /// <summary>The array a marshaller completed with, if it did.</summary>
        private byte[]? _array;

        /// <summary>True once the marshaller completed the payload.</summary>
        private bool _completed;

        /// <summary>What the serializer produced.</summary>
        /// <exception cref="InvalidOperationException">It did not complete the payload.</exception>
        public ReadOnlySpan<byte> Payload => !_completed
            ? throw new InvalidOperationException("the response marshaller returned without completing the payload")
            : _array ?? _writer.WrittenSpan;

        /// <summary>Prepares for the next response.</summary>
        /// <param name="keepCapacity">The largest buffer kept from the previous response.</param>
        public void Reset(int keepCapacity)
        {
            if (_writer.Capacity > keepCapacity)
            {
                _writer = new ArrayBufferWriter<byte>(1024);
            }
            else
            {
                _writer.ResetWrittenCount();
            }

            _array = null;
            _completed = false;
        }

        /// <summary>Takes a complete payload as an array.</summary>
        /// <param name="payload">The serialized message.</param>
        public override void Complete(byte[] payload)
        {
            _array = payload;
            _completed = true;
        }

        /// <summary>The writer the payload is written into.</summary>
        /// <returns>The writer.</returns>
        public override IBufferWriter<byte> GetBufferWriter() => _writer;

        /// <summary>Makes room for the payload up front (a hint; the writer grows anyway).</summary>
        /// <param name="payloadLength">The payload's length.</param>
        public override void SetPayloadLength(int payloadLength) => _writer.GetSpan(payloadLength);

        /// <summary>Marks the written payload complete.</summary>
        public override void Complete() => _completed = true;
    }
}
