using System.Net;
using System.Net.Sockets;
using Grpc.Core;
using GrpcAsm.Greeter.Interop;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Server.Kestrel.Core;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Xunit;
using GreeterBase = GrpcAsm.Greeter.Interop.Greeter.GreeterBase;

namespace GrpcAsm.Net.Tests;

/// <summary>
/// <see cref="GrpcAsmClient"/>: the assembly client from .NET, against GrpcAsm's own server
/// (the assembly fixture), against grpc-dotnet's Kestrel, and against servers that drop the
/// connection or never answer.
/// </summary>
/// <param name="server">The shared GrpcAsmServer (assembly fixture).</param>
public sealed class ClientTests(NetServer server)
{
    /// <summary>A client to the shared server.</summary>
    /// <returns>The connected client; the caller disposes it.</returns>
    private Task<GrpcAsmClient> Connect() =>
        GrpcAsmClient.ConnectAsync("127.0.0.1", server.RequirePort(), null, TestContext.Current.CancellationToken);

    /// <summary>A typed call: HelloRequest in, HelloReply out.</summary>
    /// <returns>A task that completes when the test has run.</returns>
    [Fact]
    public async Task A_typed_call_answers()
    {
        await using GrpcAsmClient client = await Connect();
        GrpcAsmMethod say = client.Method("/helloworld.Greeter/SayHello");
        HelloReply reply = await client.CallAsync(say, new HelloRequest { Name = "asm" }, HelloReply.Parser);
        Assert.Equal("Hello asm", reply.Message);
        Assert.Equal(say, client.Method("/helloworld.Greeter/SayHello")); // registered once
    }

    /// <summary>A raw call of 1 MiB each way: request flow control out, a multi-frame response in.</summary>
    /// <returns>A task that completes when the test has run.</returns>
    [Fact]
    public async Task A_raw_call_echoes_a_megabyte()
    {
        await using GrpcAsmClient client = await Connect();
        byte[] request = new byte[1 << 20];
        new Random(11).NextBytes(request);
        byte[] reply = await client.CallAsync(client.Method("/test.Net/Echo"), request);
        Assert.Equal(request, reply);
    }

    /// <summary>Error statuses arrive as RpcException with the decoded message.</summary>
    /// <returns>A task that completes when the test has run.</returns>
    [Fact]
    public async Task Errors_arrive_as_RpcException()
    {
        await using GrpcAsmClient client = await Connect();
        byte[] request = [(byte)StatusCode.PermissionDenied, .. "nö, 100% ✓"u8.ToArray()];
        RpcException e = await Assert.ThrowsAsync<RpcException>(() => client.CallAsync(client.Method("/test.Net/Fail"), request));
        Assert.Equal(StatusCode.PermissionDenied, e.StatusCode);
        Assert.Equal("nö, 100% ✓", e.Status.Detail);
        e = await Assert.ThrowsAsync<RpcException>(() =>
            client.CallAsync(client.Method("/test.Net/Throw"), new HelloRequest(), HelloReply.Parser));
        Assert.Equal(StatusCode.Internal, e.StatusCode);
        e = await Assert.ThrowsAsync<RpcException>(() => client.CallAsync(client.Method("/no.Such/Method"), []));
        Assert.Equal(StatusCode.Unimplemented, e.StatusCode);
    }

    /// <summary>
    /// 10,000 calls issued from 8 threads at once on one client: the lock serializes the native
    /// client, and every answer reaches its own Task.
    /// </summary>
    /// <returns>A task that completes when the test has run.</returns>
    [Fact]
    public async Task Calls_from_many_threads_get_their_own_answers()
    {
        await using GrpcAsmClient client = await Connect();
        GrpcAsmMethod say = client.Method("/helloworld.Greeter/SayHello");
        Task<HelloReply>[][] perThread = await Task.WhenAll(Enumerable.Range(0, 8).Select(t => Task.Run(() =>
            Enumerable.Range(0, 1250)
                .Select(i => client.CallAsync(say, new HelloRequest { Name = $"t{t}-{i}" }, HelloReply.Parser))
                .ToArray())));
        for (int t = 0; t < 8; t++)
        {
            HelloReply[] replies = await Task.WhenAll(perThread[t]);
            for (int i = 0; i < replies.Length; i++)
            {
                Assert.Equal($"Hello t{t}-{i}", replies[i].Message);
            }
        }
    }

    /// <summary>
    /// grpc-dotnet's server (Kestrel, Grpc.AspNetCore): Huffman-coded headers, its own dynamic
    /// table, its status encoding — against the assembly client's decoder and encoder.
    /// </summary>
    /// <returns>A task that completes when the test has run.</returns>
    [Fact]
    public async Task Kestrel_answers_the_assembly_client()
    {
        server.RequirePort(); // Linux only, like every test here
        int port = NetServer.FreePort();
        WebApplicationBuilder builder = WebApplication.CreateSlimBuilder();
        builder.Logging.ClearProviders();
        builder.WebHost.ConfigureKestrel(k => k.Listen(IPAddress.Loopback, port, l => l.Protocols = HttpProtocols.Http2));
        builder.Services.AddGrpc();
        await using WebApplication app = builder.Build();
        app.MapGrpcService<KestrelGreeter>();
        await app.StartAsync(TestContext.Current.CancellationToken);

        await using GrpcAsmClient client = await GrpcAsmClient.ConnectAsync("127.0.0.1", port, null,
            TestContext.Current.CancellationToken);
        GrpcAsmMethod say = client.Method("/helloworld.Greeter/SayHello");
        for (int i = 0; i < 50; i++) // indexed headers from the second call on
        {
            HelloReply reply = await client.CallAsync(say, new HelloRequest { Name = $"k{i}" }, HelloReply.Parser);
            Assert.Equal($"Hello k{i}", reply.Message);
        }

        RpcException e = await Assert.ThrowsAsync<RpcException>(() =>
            client.CallAsync(say, new HelloRequest { Name = "fail" }, HelloReply.Parser));
        Assert.Equal(StatusCode.FailedPrecondition, e.StatusCode);
        Assert.Equal("é not allowed", e.Status.Detail);
    }

    /// <summary>A server that closes the connection: the call in flight fails UNAVAILABLE, later calls too.</summary>
    /// <returns>A task that completes when the test has run.</returns>
    [Fact]
    public async Task A_dropped_connection_fails_calls_unavailable()
    {
        server.RequirePort();
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        int port = ((IPEndPoint)listener.LocalEndpoint).Port;
        await using GrpcAsmClient client = await GrpcAsmClient.ConnectAsync("127.0.0.1", port, null,
            TestContext.Current.CancellationToken);
        using Socket accepted = await listener.AcceptSocketAsync(TestContext.Current.CancellationToken);
        Task<byte[]> call = client.CallAsync(client.Method("/x.Y/Z"), [1, 2, 3]);
        await Task.Delay(100, TestContext.Current.CancellationToken);
        accepted.Shutdown(SocketShutdown.Both);
        accepted.Close();
        RpcException e = await Assert.ThrowsAsync<RpcException>(() => call);
        Assert.Equal(StatusCode.Unavailable, e.StatusCode);
        e = await Assert.ThrowsAsync<RpcException>(() => client.CallAsync(new GrpcAsmMethod(0, "/x.Y/Z"), []));
        Assert.Equal(StatusCode.Unavailable, e.StatusCode);
    }

    /// <summary>Disposing a client with a call in flight fails the call CANCELLED.</summary>
    /// <returns>A task that completes when the test has run.</returns>
    [Fact]
    public async Task Dispose_cancels_the_calls_in_flight()
    {
        server.RequirePort();
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        int port = ((IPEndPoint)listener.LocalEndpoint).Port;
        GrpcAsmClient client = await GrpcAsmClient.ConnectAsync("127.0.0.1", port, null,
            TestContext.Current.CancellationToken);
        using Socket accepted = await listener.AcceptSocketAsync(TestContext.Current.CancellationToken);
        Task<byte[]> call = client.CallAsync(client.Method("/x.Y/Z"), []);
        await client.DisposeAsync();
        RpcException e = await Assert.ThrowsAsync<RpcException>(() => call);
        Assert.Equal(StatusCode.Cancelled, e.StatusCode);
        Assert.Equal("client closed", e.Status.Detail);
    }

    /// <summary>A malformed method path is refused at registration.</summary>
    /// <returns>A task that completes when the test has run.</returns>
    [Fact]
    public async Task A_malformed_path_is_refused()
    {
        await using GrpcAsmClient client = await Connect();
        Assert.Throws<ArgumentException>(() => client.Method("no-slash"));
    }
}

/// <summary>The Greeter as grpc-dotnet serves it, with one error case ("fail").</summary>
public sealed class KestrelGreeter : GreeterBase
{
    /// <summary>"Hello " + name, or FAILED_PRECONDITION "é not allowed" for the name "fail".</summary>
    /// <param name="request">The request.</param>
    /// <param name="context">The call's context (unused).</param>
    /// <returns>The reply.</returns>
    /// <exception cref="RpcException">The name is "fail".</exception>
    public override Task<HelloReply> SayHello(HelloRequest request, ServerCallContext context) =>
        request.Name == "fail"
            ? throw new RpcException(new Status(StatusCode.FailedPrecondition, "é not allowed"))
            : Task.FromResult(new HelloReply { Message = "Hello " + request.Name });
}
