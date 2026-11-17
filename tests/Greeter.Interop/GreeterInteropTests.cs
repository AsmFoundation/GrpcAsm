using Grpc.Core;
using Grpc.Health.V1;
using Grpc.Net.Client;
using Xunit;

namespace GrpcAsm.Greeter.Interop;

/// <summary>
/// grpc-dotnet's client against the GrpcAsm engine (samples/Greeter): unary calls of every
/// size, multiplexing, the built-in health service, and the engine's gRPC error statuses, all
/// as a .NET client sees them.
/// </summary>
/// <param name="server">The shared Greeter (assembly fixture).</param>
public sealed class GreeterInteropTests(GreeterServer server)
{
    /// <summary>A channel to the shared Greeter (h2c: grpc-dotnet speaks HTTP/2 to http:// addresses).</summary>
    /// <returns>A new channel; the caller disposes it.</returns>
    private GrpcChannel Channel() => GrpcChannel.ForAddress(server.RequireAddress());

    /// <summary>The canonical call: SayHello("world") answers "Hello world".</summary>
    /// <returns>A task that completes when the test has run.</returns>
    [Fact]
    public async Task SayHello_answers_hello_and_the_name()
    {
        using GrpcChannel channel = Channel();
        var client = new Greeter.GreeterClient(channel);

        HelloReply reply = await client.SayHelloAsync(
            new HelloRequest { Name = "world" }, cancellationToken: TestContext.Current.CancellationToken);

        Assert.Equal("Hello world", reply.Message);
    }

    /// <summary>
    /// An empty name is proto3's default: the request is the empty message, and the answer
    /// is "Hello " (the engine passes a zero-length message to the application).
    /// </summary>
    /// <returns>A task that completes when the test has run.</returns>
    [Fact]
    public async Task SayHello_with_no_name_answers_hello_and_a_space()
    {
        using GrpcChannel channel = Channel();
        var client = new Greeter.GreeterClient(channel);

        HelloReply reply = await client.SayHelloAsync(new HelloRequest(), cancellationToken: TestContext.Current.CancellationToken);

        Assert.Equal("Hello ", reply.Message);
    }

    /// <summary>
    /// Non-ASCII names round-trip byte for byte: the engine and the Greeter never interpret
    /// the string, they copy its UTF-8 bytes.
    /// </summary>
    /// <returns>A task that completes when the test has run.</returns>
    [Fact]
    public async Task SayHello_keeps_utf8_names_intact()
    {
        using GrpcChannel channel = Channel();
        var client = new Greeter.GreeterClient(channel);

        HelloReply reply = await client.SayHelloAsync(
            new HelloRequest { Name = "שלום, 世界 🌍" }, cancellationToken: TestContext.Current.CancellationToken);

        Assert.Equal("Hello שלום, 世界 🌍", reply.Message);
    }

    /// <summary>
    /// A 1 MiB name: the request spans many DATA frames (buffered by the engine within its
    /// budgets) and the 1 MiB answer is larger than the initial flow-control windows, so it
    /// is sent as the client grants window.
    /// </summary>
    /// <returns>A task that completes when the test has run.</returns>
    [Fact]
    public async Task SayHello_with_a_1_MiB_name_crosses_frames_and_windows()
    {
        using GrpcChannel channel = Channel();
        var client = new Greeter.GreeterClient(channel);
        string name = new('x', 1 << 20);

        HelloReply reply = await client.SayHelloAsync(
            new HelloRequest { Name = name }, cancellationToken: TestContext.Current.CancellationToken);

        Assert.Equal(6 + name.Length, reply.Message.Length);
        Assert.Equal("Hello " + name, reply.Message);
    }

    /// <summary>
    /// A request above the Greeter's 4 MiB message limit is RESOURCE_EXHAUSTED: the engine
    /// stops buffering at the limit and answers at END_STREAM.
    /// </summary>
    /// <returns>A task that completes when the test has run.</returns>
    [Fact]
    public async Task A_request_above_the_limit_is_resource_exhausted()
    {
        using GrpcChannel channel = Channel();
        var client = new Greeter.GreeterClient(channel);
        string name = new('x', 5 << 20);

        RpcException e = await Assert.ThrowsAsync<RpcException>(async () =>
            await client.SayHelloAsync(new HelloRequest { Name = name }, cancellationToken: TestContext.Current.CancellationToken));

        Assert.Equal(StatusCode.ResourceExhausted, e.StatusCode);
        Assert.Equal("request message too large", e.Status.Detail);
    }

    /// <summary>
    /// 1,000 concurrent calls on one channel: grpc-dotnet multiplexes them as HTTP/2 streams.
    /// The Greeter allows 100 concurrent streams per connection; whether the client queues the
    /// rest or opens more connections is its choice. Every answer must match its own request.
    /// </summary>
    /// <returns>A task that completes when the test has run.</returns>
    [Fact]
    public async Task Concurrent_calls_on_one_channel_each_get_their_own_answer()
    {
        using GrpcChannel channel = Channel();
        var client = new Greeter.GreeterClient(channel);
        CancellationToken ct = TestContext.Current.CancellationToken;

        string[] replies = await Task.WhenAll(Enumerable.Range(0, 1000).Select(async i =>
            (await client.SayHelloAsync(new HelloRequest { Name = $"caller {i}" }, cancellationToken: ct)).Message));

        for (int i = 0; i < replies.Length; i++)
        {
            Assert.Equal($"Hello caller {i}", replies[i]);
        }
    }

    /// <summary>
    /// The engine's built-in health service, through grpc-dotnet's own health client: the
    /// whole server and the Greeter's service are SERVING; an unknown service is NOT_FOUND, as
    /// the health protocol specifies.
    /// </summary>
    /// <returns>A task that completes when the test has run.</returns>
    [Fact]
    public async Task Health_reports_serving_and_not_found()
    {
        using GrpcChannel channel = Channel();
        var health = new Health.HealthClient(channel);
        CancellationToken ct = TestContext.Current.CancellationToken;

        HealthCheckResponse whole = await health.CheckAsync(new HealthCheckRequest(), cancellationToken: ct);
        HealthCheckResponse greeter = await health.CheckAsync(
            new HealthCheckRequest { Service = "helloworld.Greeter" }, cancellationToken: ct);
        RpcException unknown = await Assert.ThrowsAsync<RpcException>(async () =>
            await health.CheckAsync(new HealthCheckRequest { Service = "nope.Service" }, cancellationToken: ct));

        Assert.Equal(HealthCheckResponse.Types.ServingStatus.Serving, whole.Status);
        Assert.Equal(HealthCheckResponse.Types.ServingStatus.Serving, greeter.Status);
        Assert.Equal(StatusCode.NotFound, unknown.StatusCode);
        Assert.Equal("unknown service", unknown.Status.Detail);
    }

    /// <summary>
    /// A method the Greeter's route table does not list is UNIMPLEMENTED, answered by the
    /// engine before the application sees the call.
    /// </summary>
    /// <returns>A task that completes when the test has run.</returns>
    [Fact]
    public async Task An_unknown_method_is_unimplemented()
    {
        using GrpcChannel channel = Channel();
        var sayGoodbye = new Method<HelloRequest, HelloReply>(
            MethodType.Unary,
            "helloworld.Greeter",
            "SayGoodbye",
            Marshallers.Create(r => Google.Protobuf.MessageExtensions.ToByteArray(r), HelloRequest.Parser.ParseFrom),
            Marshallers.Create(r => Google.Protobuf.MessageExtensions.ToByteArray(r), HelloReply.Parser.ParseFrom));

        RpcException e = await Assert.ThrowsAsync<RpcException>(async () =>
            await channel.CreateCallInvoker().AsyncUnaryCall(
                sayGoodbye, null, new CallOptions(cancellationToken: TestContext.Current.CancellationToken),
                new HelloRequest { Name = "world" }));

        Assert.Equal(StatusCode.Unimplemented, e.StatusCode);
        Assert.Equal("unknown method", e.Status.Detail);
    }
}
