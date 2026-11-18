using System.Globalization;
using System.Net;
using DotNet.Testcontainers.Builders;
using DotNet.Testcontainers.Configurations;
using DotNet.Testcontainers.Containers;
using Grpc.Core;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.AspNetCore.Server.Kestrel.Core;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Xunit;

namespace GrpcAsm.Greeter.Interop;

/// <summary>
/// GrpcAsm's client against grpc-dotnet's server: the NASM client (samples/GreeterClient,
/// <c>greeter_client</c>) runs in a stock Linux container and calls a Greeter that ASP.NET Core
/// (Kestrel, Grpc.AspNetCore) serves in this test process.
/// </summary>
/// <remarks>
/// <para>
/// Why this matters: GrpcAsm's own servers are its first peers, and they share the engine's
/// HPACK code. Kestrel shares nothing with it. Its HPACK encoder Huffman-codes the response
/// headers and indexes them in its dynamic table. Its decoder must accept the client's indexed
/// references: the client inserts its request headers on a connection's first call and indexes
/// them from the second (GREETER_CALLS repeats the call on one connection). grpc-dotnet also
/// percent-encodes a status message as UTF-8, which the client must decode back.
/// </para>
/// <para>
/// How the container reaches the test process: Testcontainers' host port forwarding
/// (<see cref="TestcontainersSettings.ExposeHostPortsAsync(ushort, CancellationToken)"/>), an SSH
/// tunnel that makes the Kestrel port appear as <c>host.testcontainers.internal</c> inside
/// containers. Kestrel therefore listens on loopback only, on Windows, macOS and Linux hosts
/// alike, and no firewall rule is needed.
/// </para>
/// <para>
/// The Greeter's SayHello understands three names, so one method covers the cases: a plain
/// name answers "Hello " + name; <c>fail:CODE:TEXT</c> fails with that status and message;
/// <c>big:N</c> answers N bytes of 'x' (many DATA frames).
/// </para>
/// </remarks>
/// <param name="server">The Kestrel Greeter and the client's container (class fixture).</param>
public sealed class ClientInteropTests(KestrelGreeter server) : IClassFixture<KestrelGreeter>
{
    /// <summary>
    /// Many calls on one connection: the first inserts the request headers into Kestrel's HPACK
    /// table, the other 199 send them as indexed references (6 bytes), and every reply comes
    /// back through Kestrel's own table and Huffman coding.
    /// </summary>
    /// <returns>A task that completes when the test has run.</returns>
    [Fact]
    public async Task Repeated_calls_on_one_connection_are_answered()
    {
        ExecResult result = await CallAsync("dotnet", calls: 200);

        Assert.Equal(0, result.ExitCode);
        Assert.Equal("Hello dotnet\n", result.Stdout);
    }

    /// <summary>A failed call: grpc-dotnet's status and message reach the client unchanged.</summary>
    /// <returns>A task that completes when the test has run.</returns>
    [Fact]
    public async Task An_error_status_and_its_message_arrive()
    {
        ExecResult result = await CallAsync("fail:5:nothing here");

        Assert.Equal(1, result.ExitCode);
        Assert.Equal("greeter_client: status 5: nothing here\n", result.Stderr);
    }

    /// <summary>
    /// A message that is not ASCII: grpc-dotnet percent-encodes its UTF-8 bytes, and the client
    /// decodes them back to the same bytes.
    /// </summary>
    /// <returns>A task that completes when the test has run.</returns>
    [Fact]
    public async Task A_unicode_message_is_percent_decoded()
    {
        ExecResult result = await CallAsync("fail:3:héllo wörld ✓ 100%");

        Assert.Equal(1, result.ExitCode);
        Assert.Equal("greeter_client: status 3: héllo wörld ✓ 100%\n", result.Stderr);
    }

    /// <summary>A 200,000-byte reply: many DATA frames, reassembled by the client.</summary>
    /// <returns>A task that completes when the test has run.</returns>
    [Fact]
    public async Task A_large_reply_arrives_whole()
    {
        ExecResult result = await CallAsync("big:200000", calls: 3);

        Assert.Equal(0, result.ExitCode);
        Assert.Equal(new string('x', 200000) + "\n", result.Stdout);
    }

    /// <summary>Runs <c>greeter_client</c> in the container against Kestrel.</summary>
    /// <param name="name">The HelloRequest's name (see the class remarks for the special ones).</param>
    /// <param name="calls">How many calls the client makes on its one connection.</param>
    /// <returns>The client's exit code, stdout and stderr.</returns>
    private async Task<ExecResult> CallAsync(string name, int calls = 1)
    {
        IContainer container = server.RequireContainer();
        return await container.ExecAsync(
            [
                "env", "GREETER_HOST=host.testcontainers.internal",
                "GREETER_PORT=" + server.Port.ToString(CultureInfo.InvariantCulture),
                "GREETER_CALLS=" + calls.ToString(CultureInfo.InvariantCulture),
                "/gc/greeter_client", name,
            ],
            TestContext.Current.CancellationToken);
    }
}

/// <summary>
/// The Greeter as grpc-dotnet serves it, with two test hooks in the name (see
/// <see cref="ClientInteropTests"/>).
/// </summary>
public sealed class DotnetGreeter : Greeter.GreeterBase
{
    /// <summary>
    /// "Hello " + name; or, for <c>fail:CODE:TEXT</c>, the status CODE with the message TEXT; or,
    /// for <c>big:N</c>, N bytes of 'x'.
    /// </summary>
    /// <param name="request">The request.</param>
    /// <param name="context">The call's context (unused).</param>
    /// <returns>The reply.</returns>
    /// <exception cref="RpcException">The name asked for a failure.</exception>
    public override Task<HelloReply> SayHello(HelloRequest request, ServerCallContext context)
    {
        string name = request.Name;
        if (name.StartsWith("fail:", StringComparison.Ordinal))
        {
            string[] parts = name.Split(':', 3);
            var code = (StatusCode)int.Parse(parts[1], CultureInfo.InvariantCulture);
            throw new RpcException(new Status(code, parts[2]));
        }

        if (name.StartsWith("big:", StringComparison.Ordinal))
        {
            int size = int.Parse(name.AsSpan(4), CultureInfo.InvariantCulture);
            return Task.FromResult(new HelloReply { Message = new string('x', size) });
        }

        return Task.FromResult(new HelloReply { Message = "Hello " + name });
    }
}

/// <summary>
/// The other side of <see cref="ClientInteropTests"/>: Kestrel serving <see cref="DotnetGreeter"/>
/// on a loopback port, that port forwarded into containers, and one idle container holding the
/// NASM client. Created once for the test class.
/// </summary>
public sealed class KestrelGreeter : IAsyncLifetime
{
    private WebApplication? _app;
    private IContainer? _container;
    private string? _unavailableReason;

    /// <summary>The Kestrel port (forwarded as host.testcontainers.internal:Port).</summary>
    public int Port { get; private set; }

    /// <summary>
    /// Starts Kestrel with the Greeter on a loopback port, forwards that port into containers,
    /// and starts the container that runs the client, or records why this cannot run.
    /// </summary>
    /// <returns>A task that completes when everything listens, or the failure is recorded.</returns>
    /// <exception cref="Exception">Startup failed and <see cref="GreeterServer.DockerRequired"/> is set.</exception>
    public async ValueTask InitializeAsync()
    {
        try
        {
            string client = LocateClient();
            WebApplicationBuilder builder = WebApplication.CreateSlimBuilder();
            builder.Logging.ClearProviders();
            // HTTP/2 only on a cleartext port: prior knowledge (h2c), what gRPC clients speak.
            builder.WebHost.ConfigureKestrel(kestrel =>
                kestrel.Listen(IPAddress.Loopback, 0, listen => listen.Protocols = HttpProtocols.Http2));
            builder.Services.AddGrpc();
            _app = builder.Build();
            _app.MapGrpcService<DotnetGreeter>();
            await _app.StartAsync(CancellationToken.None);
            // Port 0: the bound address is known only once Kestrel has started.
            string address = _app.Services.GetRequiredService<IServer>().Features
                .Get<IServerAddressesFeature>()!.Addresses.First();
            Port = new Uri(address).Port;
            await TestcontainersSettings.ExposeHostPortsAsync((ushort)Port, CancellationToken.None);
            _container = new ContainerBuilder(GreeterServer.Image)
                // The client is copied in with its execute bits (no bind mount: the same on
                // every host), and the container idles so each test can run it with exec.
                .WithResourceMapping(await File.ReadAllBytesAsync(client, CancellationToken.None),
                    FilePath.Of("/gc/greeter_client"), fileMode: Unix.FileMode755)
                .WithEntrypoint("sleep", "infinity")
                .Build();
            await _container.StartAsync(CancellationToken.None);
        }
        catch (Exception e) when (!GreeterServer.DockerRequired)
        {
            _unavailableReason = $"client interop unavailable ({e.GetType().Name}: {e.Message}). Build the " +
                                 "solution, start Docker, or set GRPCASM_REQUIRE_DOCKER=1 to fail instead of skipping.";
        }
    }

    /// <summary>Removes the container and stops Kestrel.</summary>
    /// <returns>A task that completes when both are gone.</returns>
    public async ValueTask DisposeAsync()
    {
        if (_container is not null)
        {
            await _container.DisposeAsync();
        }

        if (_app is not null)
        {
            await _app.DisposeAsync();
        }
    }

    /// <summary>The container that runs the client; skips the calling test when it is unavailable.</summary>
    /// <returns>The running container.</returns>
    public IContainer RequireContainer()
    {
        if (_unavailableReason is not null)
        {
            Assert.Skip(_unavailableReason);
        }

        return _container!;
    }

    /// <summary>
    /// Finds the NASM client: <c>GREETER_CLIENT_BINARY</c> when set, else
    /// <c>samples/GreeterClient/bin/Release/greeter_client</c> under the first ancestor of the
    /// test assembly that holds <c>GrpcAsm.slnx</c>.
    /// </summary>
    /// <returns>The executable's full path.</returns>
    /// <exception cref="FileNotFoundException">No such file: the solution was not built (Release).</exception>
    private static string LocateClient()
    {
        if (Environment.GetEnvironmentVariable("GREETER_CLIENT_BINARY") is { Length: > 0 } configured)
        {
            return File.Exists(configured)
                ? configured
                : throw new FileNotFoundException("GREETER_CLIENT_BINARY does not exist", configured);
        }

        for (DirectoryInfo? dir = new(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
        {
            if (File.Exists(Path.Combine(dir.FullName, "GrpcAsm.slnx")))
            {
                string candidate = Path.Combine(dir.FullName, "samples", "GreeterClient", "bin", "Release",
                    "greeter_client");
                return File.Exists(candidate)
                    ? candidate
                    : throw new FileNotFoundException("build first: dotnet build GrpcAsm.slnx -c Release", candidate);
            }
        }

        throw new FileNotFoundException("GrpcAsm.slnx not found above the test assembly; set GREETER_CLIENT_BINARY");
    }
}
