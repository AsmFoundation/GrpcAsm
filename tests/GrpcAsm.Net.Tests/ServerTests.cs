using Google.Protobuf;
using Grpc.Core;
using Grpc.Health.V1;
using Grpc.Net.Client;
using GrpcAsm.Greeter.Interop;
using Xunit;
using GreeterClient = GrpcAsm.Greeter.Interop.Greeter.GreeterClient;

namespace GrpcAsm.Net.Tests;

/// <summary>
/// <see cref="GrpcAsmServer"/>'s .NET handlers as grpc-dotnet's client sees them: typed and raw
/// methods, every way a handler can fail, the engine's own health service, concurrency, and the
/// one-server-per-process rule.
/// </summary>
/// <param name="server">The shared server (assembly fixture).</param>
public sealed class ServerTests(NetServer server)
{
    /// <summary>A grpc-dotnet channel to the shared server (h2c).</summary>
    /// <returns>A new channel; the caller disposes it.</returns>
    private GrpcChannel Channel() => GrpcChannel.ForAddress($"http://127.0.0.1:{server.RequirePort()}");

    /// <summary>A raw unary call through grpc-dotnet: bytes in, bytes out.</summary>
    /// <param name="channel">The channel.</param>
    /// <param name="path">"/service/method".</param>
    /// <param name="request">The request bytes.</param>
    /// <returns>The response bytes.</returns>
    private static Task<byte[]> RawCall(GrpcChannel channel, string path, byte[] request)
    {
        string[] parts = path.Split('/');
        var method = new Method<byte[], byte[]>(MethodType.Unary, parts[1], parts[2],
            Marshallers.Create(b => b, b => b), Marshallers.Create(b => b, b => b));
        return channel.CreateCallInvoker()
            .AsyncUnaryCall(method, null, new CallOptions(cancellationToken: TestContext.Current.CancellationToken), request)
            .ResponseAsync;
    }

    /// <summary>The typed delegate handler (AddUnary&lt;,&gt;): parsed request, serialized reply.</summary>
    /// <returns>A task that completes when the test has run.</returns>
    [Fact]
    public async Task A_typed_handler_answers()
    {
        using GrpcChannel channel = Channel();
        var method = new Method<HelloRequest, HelloReply>(MethodType.Unary, "test.Net", "TypedHello",
            Marshallers.Create(r => r.ToByteArray(), HelloRequest.Parser.ParseFrom),
            Marshallers.Create(r => r.ToByteArray(), HelloReply.Parser.ParseFrom));
        HelloReply reply = await channel.CreateCallInvoker()
            .AsyncUnaryCall(method, null, new CallOptions(cancellationToken: TestContext.Current.CancellationToken),
                new HelloRequest { Name = "dotnet" }).ResponseAsync;
        Assert.Equal("Hello dotnet", reply.Message);
    }

    /// <summary>
    /// helloworld.Greeter/SayHello is the sample's grpc-dotnet class, bound through the
    /// ServiceBinder: the interop project's client (other C# namespace, same wire) gets its answer.
    /// </summary>
    /// <returns>A task that completes when the test has run.</returns>
    [Fact]
    public async Task A_bound_service_class_answers()
    {
        using GrpcChannel channel = Channel();
        HelloReply reply = await new GreeterClient(channel).SayHelloAsync(
            new HelloRequest { Name = "class" }, cancellationToken: TestContext.Current.CancellationToken);
        Assert.Equal("Hello class", reply.Message);
    }

    /// <summary>A raw handler, 1 MiB each way: the reply leaves through the engine's buffered path.</summary>
    /// <returns>A task that completes when the test has run.</returns>
    [Fact]
    public async Task A_raw_handler_echoes_a_megabyte()
    {
        using GrpcChannel channel = Channel();
        byte[] request = new byte[1 << 20];
        new Random(7).NextBytes(request);
        byte[] reply = await RawCall(channel, "/test.Net/Echo", request);
        Assert.Equal(request, reply);
    }

    /// <summary>GrpcAsmCall.Fail: the status and a UTF-8 message, percent-encoded on the wire.</summary>
    /// <returns>A task that completes when the test has run.</returns>
    [Fact]
    public async Task Fail_sends_the_status_and_its_message()
    {
        using GrpcChannel channel = Channel();
        byte[] request = [(byte)StatusCode.PermissionDenied, .. "nö, 100% ✓"u8.ToArray()];
        RpcException e = await Assert.ThrowsAsync<RpcException>(() => RawCall(channel, "/test.Net/Fail", request));
        Assert.Equal(StatusCode.PermissionDenied, e.StatusCode);
        Assert.Equal("nö, 100% ✓", e.Status.Detail);
    }

    /// <summary>
    /// An exception from a delegate handler: UNKNOWN with grpc-dotnet's text, as from a bound
    /// service class and from ASP.NET Core (ParityTests), and the worker carries on.
    /// </summary>
    /// <returns>A task that completes when the test has run.</returns>
    [Fact]
    public async Task A_throwing_handler_is_answered_unknown()
    {
        using GrpcChannel channel = Channel();
        var method = new Method<HelloRequest, HelloReply>(MethodType.Unary, "test.Net", "Throw",
            Marshallers.Create(r => r.ToByteArray(), HelloRequest.Parser.ParseFrom),
            Marshallers.Create(r => r.ToByteArray(), HelloReply.Parser.ParseFrom));
        RpcException e = await Assert.ThrowsAsync<RpcException>(() => channel.CreateCallInvoker()
            .AsyncUnaryCall(method, null, new CallOptions(cancellationToken: TestContext.Current.CancellationToken),
                new HelloRequest()).ResponseAsync);
        Assert.Equal(StatusCode.Unknown, e.StatusCode);
        Assert.Equal("Exception was thrown by handler.", e.Status.Detail);
        // The same worker still serves.
        HelloReply reply = await new GreeterClient(channel).SayHelloAsync(
            new HelloRequest { Name = "after" }, cancellationToken: TestContext.Current.CancellationToken);
        Assert.Equal("Hello after", reply.Message);
    }

    /// <summary>An RpcException from a handler: its own status and detail.</summary>
    /// <returns>A task that completes when the test has run.</returns>
    [Fact]
    public async Task An_RpcException_keeps_its_status()
    {
        using GrpcChannel channel = Channel();
        var method = new Method<HelloRequest, HelloReply>(MethodType.Unary, "test.Net", "RpcFail",
            Marshallers.Create(r => r.ToByteArray(), HelloRequest.Parser.ParseFrom),
            Marshallers.Create(r => r.ToByteArray(), HelloReply.Parser.ParseFrom));
        RpcException e = await Assert.ThrowsAsync<RpcException>(() => channel.CreateCallInvoker()
            .AsyncUnaryCall(method, null, new CallOptions(cancellationToken: TestContext.Current.CancellationToken),
                new HelloRequest()).ResponseAsync);
        Assert.Equal(StatusCode.NotFound, e.StatusCode);
        Assert.Equal("nope", e.Status.Detail);
    }

    /// <summary>A handler that answers, then throws: the answer stands.</summary>
    /// <returns>A task that completes when the test has run.</returns>
    [Fact]
    public async Task An_answer_given_before_an_exception_stands()
    {
        using GrpcChannel channel = Channel();
        byte[] reply = await RawCall(channel, "/test.Net/AnswerThenThrow", []);
        Assert.Equal("ok"u8.ToArray(), reply);
    }

    /// <summary>The engine's health service knows the .NET services by their registered paths.</summary>
    /// <returns>A task that completes when the test has run.</returns>
    [Fact]
    public async Task Health_reports_the_registered_services()
    {
        using GrpcChannel channel = Channel();
        var health = new Health.HealthClient(channel);
        HealthCheckResponse greeter = await health.CheckAsync(new HealthCheckRequest { Service = "helloworld.Greeter" },
            cancellationToken: TestContext.Current.CancellationToken);
        Assert.Equal(HealthCheckResponse.Types.ServingStatus.Serving, greeter.Status);
        RpcException e = await Assert.ThrowsAsync<RpcException>(async () => await health.CheckAsync(
            new HealthCheckRequest { Service = "nothing.Here" }, cancellationToken: TestContext.Current.CancellationToken));
        Assert.Equal(StatusCode.NotFound, e.StatusCode);
    }

    /// <summary>2,000 calls at once on one channel: handlers on two workers, every answer its own.</summary>
    /// <returns>A task that completes when the test has run.</returns>
    [Fact]
    public async Task Concurrent_calls_get_their_own_answers()
    {
        using GrpcChannel channel = Channel();
        var client = new GreeterClient(channel);
        Task<HelloReply>[] calls = Enumerable.Range(0, 2000)
            .Select(i => client.SayHelloAsync(new HelloRequest { Name = $"n{i}" },
                cancellationToken: TestContext.Current.CancellationToken).ResponseAsync)
            .ToArray();
        HelloReply[] replies = await Task.WhenAll(calls);
        for (int i = 0; i < replies.Length; i++)
        {
            Assert.Equal($"Hello n{i}", replies[i].Message);
        }
    }

    /// <summary>One started server per process: a second Start is refused, and its Dispose leaves the first running.</summary>
    /// <returns>A task that completes when the test has run.</returns>
    [Fact]
    public async Task A_second_server_cannot_start_while_one_runs()
    {
        server.RequirePort();
        using (var second = new GrpcAsmServer(new GrpcAsmServerOptions { Port = NetServer.FreePort() }))
        {
            second.AddUnary("/x.Y/Z", (_, call) => call.Reply([]));
            Assert.Throws<InvalidOperationException>(second.Start);
        }

        using GrpcChannel channel = Channel();
        HelloReply reply = await new GreeterClient(channel).SayHelloAsync(
            new HelloRequest { Name = "still" }, cancellationToken: TestContext.Current.CancellationToken);
        Assert.Equal("Hello still", reply.Message);
    }

    /// <summary>Options out of range are refused before anything exists.</summary>
    [Fact]
    public void Options_out_of_range_are_refused()
    {
        server.RequirePort();
        Assert.Throws<ArgumentOutOfRangeException>(() => new GrpcAsmServer(new GrpcAsmServerOptions { Workers = 1000 }));
        Assert.Throws<ArgumentOutOfRangeException>(() => new GrpcAsmServer(new GrpcAsmServerOptions { Port = 70000 }));
    }
}
