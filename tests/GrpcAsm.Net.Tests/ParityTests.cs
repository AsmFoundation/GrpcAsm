using Google.Protobuf;
using Grpc.Core;
using Grpc.Net.Client;
using GrpcAsm.Net.Tests.Protos;
using GrpcAsm.Samples;
using SampleGreeter = GrpcAsm.Samples.Greeter;
using Xunit;

namespace GrpcAsm.Net.Tests;

/// <summary>
/// The same grpc-dotnet service classes on both servers: GrpcAsmServer, bound through
/// <see cref="GrpcAsmServer.ServiceBinder"/> (<see cref="NetServer"/>), and ASP.NET Core gRPC
/// (<see cref="KestrelServer"/>), called by the same grpc-dotnet client.
/// </summary>
/// <remarks>
/// Two kinds of test:
/// <list type="bullet">
/// <item>Parity: what a client gets must be the same from both servers, answers and errors
/// alike. The error tests compare the two servers' outcomes directly, so they hold whatever
/// grpc-dotnet's choices are; a separate test pins the values GrpcAsm.Net documents.</item>
/// <item>Documented differences: what GrpcAsm refuses today (a handler that really awaits,
/// custom response headers and trailers, a streaming method) and the context's partial
/// contents. Each such test asserts both sides, so it shows the difference rather than hide it.</item>
/// </list>
/// Off Linux every test is skipped with GrpcAsmServer's reason (both halves together).
/// </remarks>
/// <param name="grpcAsm">The GrpcAsmServer fixture.</param>
/// <param name="kestrel">The Kestrel fixture.</param>
public sealed class ParityTests(NetServer grpcAsm, KestrelServer kestrel)
{
    /// <summary>The two servers, by name.</summary>
    public static TheoryData<string> Servers => new() { "grpcasm", "aspnet" };

    /// <summary>The test.Binder methods that end in an error status.</summary>
    public static TheoryData<string> ErrorMethods => new() { "Throw", "RpcFail", "FaultedTask", "NullReply", "SetStatus" };

    /// <summary>The marshaller of <see cref="Probe"/>, for calls by method name.</summary>
    private static readonly Marshaller<Probe> ProbeMarshaller = Marshallers.Create(p => p.ToByteArray(), Probe.Parser.ParseFrom);

    /// <summary>Call options with the test's cancellation.</summary>
    private static CallOptions Options => new(cancellationToken: TestContext.Current.CancellationToken);

    /// <summary>A channel to one of the servers (skips off Linux, for both).</summary>
    /// <param name="server">"grpcasm" or "aspnet".</param>
    /// <returns>A new channel; the caller disposes it.</returns>
    private GrpcChannel Channel(string server)
    {
        int asmPort = grpcAsm.RequirePort();
        return GrpcChannel.ForAddress($"http://127.0.0.1:{(server == "grpcasm" ? asmPort : kestrel.Port)}");
    }

    /// <summary>Calls a test.Binder method by name with a text.</summary>
    /// <param name="channel">The channel.</param>
    /// <param name="method">The method's name.</param>
    /// <param name="text">The probe's text.</param>
    /// <returns>The call, for its response and trailers.</returns>
    private static AsyncUnaryCall<Probe> Call(GrpcChannel channel, string method, string text) =>
        channel.CreateCallInvoker().AsyncUnaryCall(
            new Method<Probe, Probe>(MethodType.Unary, "test.Binder", method, ProbeMarshaller, ProbeMarshaller),
            null, Options, new Probe { Text = text });

    /// <summary>What a client gets from a test.Binder method: OK and the reply's text, or the error.</summary>
    /// <param name="server">"grpcasm" or "aspnet".</param>
    /// <param name="method">The method's name.</param>
    /// <returns>The status code and the reply's text or the status detail.</returns>
    private async Task<(StatusCode Code, string Detail)> Outcome(string server, string method)
    {
        using GrpcChannel channel = Channel(server);
        try
        {
            Probe reply = await Call(channel, method, "x").ResponseAsync;
            return (StatusCode.OK, reply.Text);
        }
        catch (RpcException e)
        {
            return (e.StatusCode, e.Status.Detail);
        }
    }

    // ---- parity: the same answers ----

    /// <summary>GreeterService answers the same on both servers.</summary>
    /// <param name="server">The server.</param>
    /// <returns>A task that completes when the test has run.</returns>
    [Theory]
    [MemberData(nameof(Servers))]
    public async Task SayHello_answers_the_same(string server)
    {
        using GrpcChannel channel = Channel(server);
        HelloReply reply = await new SampleGreeter.GreeterClient(channel).SayHelloAsync(new HelloRequest { Name = "parity" }, Options);
        Assert.Equal("Hello parity", reply.Message);
    }

    /// <summary>OrdersService prices the benchmark's order the same on both servers (the amounts SampleOrders documents).</summary>
    /// <param name="server">The server.</param>
    /// <returns>A task that completes when the test has run.</returns>
    [Theory]
    [MemberData(nameof(Servers))]
    public async Task Orders_prices_the_benchmark_order(string server)
    {
        using GrpcChannel channel = Channel(server);
        Receipt receipt = await new Orders.OrdersClient(channel).PlaceAsync(SampleOrders.Benchmark(), Options);
        Assert.Equal("ord-2026-11-20-000001", receipt.OrderId);
        Assert.Equal(222_976, receipt.SubtotalCents);
        Assert.Equal(22_297, receipt.DiscountCents);
        Assert.Equal(200_679, receipt.TotalCents);
        Assert.Equal(24u, receipt.Items);
        Assert.Equal("EUR", receipt.Currency);
        Assert.Equal("ACCEPTED", receipt.Status);
    }

    /// <summary>An order without lines is INVALID_ARGUMENT with its reason on both servers.</summary>
    /// <param name="server">The server.</param>
    /// <returns>A task that completes when the test has run.</returns>
    [Theory]
    [MemberData(nameof(Servers))]
    public async Task Orders_refuses_a_broken_order(string server)
    {
        using GrpcChannel channel = Channel(server);
        Order order = SampleOrders.Benchmark();
        order.Lines.Clear();
        RpcException e = await Assert.ThrowsAsync<RpcException>(() => new Orders.OrdersClient(channel).PlaceAsync(order, Options).ResponseAsync);
        Assert.Equal(StatusCode.InvalidArgument, e.StatusCode);
        Assert.Equal("an order has at least one line", e.Status.Detail);
    }

    /// <summary>The benchmark's second workload is what it claims: about 1 KiB on the wire.</summary>
    [Fact]
    public void The_benchmark_order_is_about_a_kibibyte() => Assert.InRange(SampleOrders.Benchmark().CalculateSize(), 900, 1300);

    /// <summary>
    /// Every way a method can fail reaches the client as it does from ASP.NET Core: the same
    /// status and the same detail (compared directly, server against server).
    /// </summary>
    /// <param name="method">The test.Binder method.</param>
    /// <returns>A task that completes when the test has run.</returns>
    [Theory]
    [MemberData(nameof(ErrorMethods))]
    public async Task An_error_reaches_the_client_as_from_ASP_NET_Core(string method) =>
        Assert.Equal(await Outcome("aspnet", method), await Outcome("grpcasm", method));

    /// <summary>The statuses GrpcAsmServiceBinder documents (grpc-dotnet's, checked by the parity test above).</summary>
    /// <returns>A task that completes when the test has run.</returns>
    [Fact]
    public async Task Errors_have_the_documented_statuses()
    {
        Assert.Equal((StatusCode.Unknown, "Exception was thrown by handler."), await Outcome("grpcasm", "Throw"));
        Assert.Equal((StatusCode.NotFound, "nope"), await Outcome("grpcasm", "RpcFail"));
        Assert.Equal((StatusCode.Unknown, "Exception was thrown by handler."), await Outcome("grpcasm", "FaultedTask"));
        Assert.Equal((StatusCode.Cancelled, "No message returned from method."), await Outcome("grpcasm", "NullReply"));
        Assert.Equal((StatusCode.PermissionDenied, "set"), await Outcome("grpcasm", "SetStatus"));
    }

    /// <summary>
    /// A request the method's marshaller cannot read (the Greeter suite's malformed HelloRequest:
    /// field 1 announces 9 bytes, none follow): the status and detail each server sends.
    /// </summary>
    /// <param name="server">The server.</param>
    /// <returns>The outcome.</returns>
    private async Task<(StatusCode Code, string Detail)> MalformedSayHello(string server)
    {
        using GrpcChannel channel = Channel(server);
        Marshaller<byte[]> bytes = Marshallers.Create(b => b, b => b);
        try
        {
            await channel.CreateCallInvoker().AsyncUnaryCall(
                new Method<byte[], byte[]>(MethodType.Unary, "helloworld.Greeter", "SayHello", bytes, bytes),
                null, Options, [0x0A, 0x09]).ResponseAsync;
            return (StatusCode.OK, "");
        }
        catch (RpcException e)
        {
            return (e.StatusCode, e.Status.Detail);
        }
    }

    /// <summary>A malformed request is refused with the same status and detail by both servers.</summary>
    /// <returns>A task that completes when the test has run.</returns>
    [Fact]
    public async Task A_malformed_request_is_refused_as_by_ASP_NET_Core() =>
        Assert.Equal(await MalformedSayHello("aspnet"), await MalformedSayHello("grpcasm"));

    /// <summary>An async method that completes without really awaiting is answered normally on both.</summary>
    /// <param name="server">The server.</param>
    /// <returns>A task that completes when the test has run.</returns>
    [Theory]
    [MemberData(nameof(Servers))]
    public async Task An_async_method_that_completes_synchronously_answers(string server) =>
        Assert.Equal((StatusCode.OK, "x"), await Outcome(server, "AsyncCompleted"));

    /// <summary>
    /// A 2 MiB reply through the bound path (the per-worker serialization buffer grows, and is
    /// dropped afterwards), then a small one: both arrive intact, on both servers.
    /// </summary>
    /// <param name="server">The server.</param>
    /// <returns>A task that completes when the test has run.</returns>
    [Theory]
    [MemberData(nameof(Servers))]
    public async Task A_large_reply_then_a_small_one_arrive_intact(string server)
    {
        using GrpcChannel channel = Channel(server);
        string big = new('ż', 1 << 20); // 2 MiB of UTF-8
        Probe reply = await Call(channel, "AsyncCompleted", big).ResponseAsync;
        Assert.Equal(big, reply.Text);
        reply = await Call(channel, "AsyncCompleted", "small").ResponseAsync;
        Assert.Equal("small", reply.Text);
    }

    /// <summary>A method the service does not have is UNIMPLEMENTED on both.</summary>
    /// <param name="server">The server.</param>
    /// <returns>A task that completes when the test has run.</returns>
    [Theory]
    [MemberData(nameof(Servers))]
    public async Task An_unknown_method_is_unimplemented(string server) =>
        Assert.Equal(StatusCode.Unimplemented, (await Outcome(server, "NoSuchMethod")).Code);

    // ---- documented differences ----

    /// <summary>
    /// A handler that really awaits: ASP.NET Core answers it, GrpcAsm refuses it UNIMPLEMENTED with
    /// the reason (it needs the answer before the handler returns), and its worker carries on.
    /// </summary>
    /// <returns>A task that completes when the test has run.</returns>
    [Fact]
    public async Task A_handler_that_really_awaits_is_refused_by_GrpcAsm_only()
    {
        Assert.Equal((StatusCode.OK, "x"), await Outcome("aspnet", "Pending"));
        (StatusCode code, string detail) = await Outcome("grpcasm", "Pending");
        Assert.Equal(StatusCode.Unimplemented, code);
        Assert.Equal("/test.Binder/Pending returned a Task that had not completed: GrpcAsm runs handlers inline and " +
                     "needs the answer before the handler returns (asynchronous handlers are not supported yet).", detail);
        Assert.Equal((StatusCode.OK, "x"), await Outcome("grpcasm", "AsyncCompleted"));
    }

    /// <summary>Response trailers: sent by ASP.NET Core; refused by GrpcAsm rather than silently dropped.</summary>
    /// <returns>A task that completes when the test has run.</returns>
    [Fact]
    public async Task Response_trailers_are_refused_by_GrpcAsm_only()
    {
        using (GrpcChannel channel = Channel("aspnet"))
        {
            AsyncUnaryCall<Probe> call = Call(channel, "Trailers", "x");
            Assert.Equal("x", (await call.ResponseAsync).Text);
            Assert.Equal("1", call.GetTrailers().GetValue("x-test"));
        }

        Assert.Equal((StatusCode.Unimplemented, "GrpcAsm cannot send custom response trailers yet; ResponseTrailers must stay empty."),
            await Outcome("grpcasm", "Trailers"));
    }

    /// <summary>Custom response headers: sent by ASP.NET Core; refused by GrpcAsm with the reason.</summary>
    /// <returns>A task that completes when the test has run.</returns>
    [Fact]
    public async Task Response_headers_are_refused_by_GrpcAsm_only()
    {
        Assert.Equal((StatusCode.OK, "x"), await Outcome("aspnet", "Headers"));
        Assert.Equal((StatusCode.Unimplemented, "GrpcAsm cannot send custom response headers yet."), await Outcome("grpcasm", "Headers"));
    }

    /// <summary>
    /// The context: the same method name on both; on GrpcAsm no host, peer, request headers or
    /// cancellation (the C ABI passes the message only), where ASP.NET Core has all four.
    /// </summary>
    /// <returns>A task that completes when the test has run.</returns>
    [Fact]
    public async Task The_context_is_partial_on_GrpcAsm()
    {
        Assert.Equal((StatusCode.OK, "/test.Binder/Context|||True|0|False"), await Outcome("grpcasm", "Context"));
        (StatusCode code, string text) = await Outcome("aspnet", "Context");
        Assert.Equal(StatusCode.OK, code);
        string[] parts = text.Split('|');
        Assert.Equal("/test.Binder/Context", parts[0]);
        Assert.NotEmpty(parts[1]); // host
        Assert.NotEmpty(parts[2]); // peer
        Assert.Equal("True", parts[3]); // no deadline set by the client
        Assert.NotEqual("0", parts[4]); // request headers
        Assert.Equal("True", parts[5]); // cancellable
    }

    /// <summary>A service with a streaming method is refused when it is bound, naming the method, before anything runs.</summary>
    [Fact]
    public void A_streaming_method_is_refused_when_bound()
    {
        grpcAsm.RequirePort();
        using var server = new GrpcAsmServer(new GrpcAsmServerOptions { Port = NetServer.FreePort() });
        NotSupportedException e = Assert.Throws<NotSupportedException>(() =>
            Streaming.BindService(server.ServiceBinder, new StreamingService()));
        Assert.Equal("/test.Streaming/Upload is a ClientStreaming method: GrpcAsm hosts unary methods only " +
                     "(its C ABI has no streaming calls yet).", e.Message);
    }

    /// <summary>A service bound without an instance (the generated method's null case) is refused.</summary>
    [Fact]
    public void A_service_without_an_instance_is_refused()
    {
        grpcAsm.RequirePort();
        using var server = new GrpcAsmServer(new GrpcAsmServerOptions { Port = NetServer.FreePort() });
        Assert.Throws<ArgumentNullException>(() => SampleGreeter.BindService(server.ServiceBinder, null!));
    }

    /// <summary>Binding on a started server is refused, as AddUnary is.</summary>
    [Fact]
    public void Binding_on_a_started_server_is_refused()
    {
        grpcAsm.RequirePort();
        Assert.Throws<InvalidOperationException>(() => SampleGreeter.BindService(grpcAsm.Server!.ServiceBinder, new GreeterService()));
    }
}
