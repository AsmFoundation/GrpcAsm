using System.Net;
using System.Net.Sockets;
using System.Text;
using Grpc.Core;
using GrpcAsm.Greeter.Interop;
using Xunit;

[assembly: AssemblyFixture(typeof(GrpcAsm.Net.Tests.NetServer))]

namespace GrpcAsm.Net.Tests;

/// <summary>
/// The one <see cref="GrpcAsmServer"/> of the test assembly (the C ABI allows one started
/// server per process), with the methods the tests call.
/// </summary>
/// <remarks>
/// <para>Methods (handlers run inline on the engine's two workers):</para>
/// <list type="bullet">
/// <item><c>/helloworld.Greeter/SayHello</c> (typed): "Hello " + name.</item>
/// <item><c>/test.Net/Echo</c> (raw): the request's bytes back.</item>
/// <item><c>/test.Net/Fail</c> (raw): request [status][UTF-8 message] answered with that status.</item>
/// <item><c>/test.Net/Throw</c> (typed): throws InvalidOperationException (INTERNAL).</item>
/// <item><c>/test.Net/RpcFail</c> (typed): throws RpcException(NOT_FOUND, "nope").</item>
/// <item><c>/test.Net/AnswerThenThrow</c> (raw): replies, then throws (the reply stands).</item>
/// </list>
/// <para>
/// Not Linux, or no library: tests are skipped with the reason, unless
/// <c>GRPCASM_REQUIRE_LINUX=1</c>, which makes it a failure (CI).
/// </para>
/// </remarks>
public sealed class NetServer : IAsyncLifetime
{
    private GrpcAsmServer? _server;

    /// <summary>The port the server listens on (127.0.0.1).</summary>
    public int Port { get; private set; }

    /// <summary>Why the server could not run, or null.</summary>
    public string? UnavailableReason { get; private set; }

    /// <summary>True when the tests must fail rather than skip off Linux.</summary>
    public static bool LinuxRequired => Environment.GetEnvironmentVariable("GRPCASM_REQUIRE_LINUX") == "1";

    /// <summary>Starts the server with the test methods, or records why it cannot run.</summary>
    /// <returns>A completed task.</returns>
    /// <exception cref="Exception">The server could not start and <see cref="LinuxRequired"/> is set.</exception>
    public ValueTask InitializeAsync()
    {
        try
        {
            if (!OperatingSystem.IsLinux() || !Environment.Is64BitProcess)
            {
                throw new PlatformNotSupportedException("libgrpcasm.so runs on Linux x64 only (use tests/dotnet.sh)");
            }

            Port = FreePort();
            _server = new GrpcAsmServer(new GrpcAsmServerOptions { Port = Port, Workers = 2 });
            _server.AddUnary<HelloRequest, HelloReply>("/helloworld.Greeter/SayHello",
                request => new HelloReply { Message = "Hello " + request.Name });
            _server.AddUnary("/test.Net/Echo", (request, call) => call.Reply(request));
            _server.AddUnary("/test.Net/Fail", (request, call) =>
                call.Fail((StatusCode)request[0], Encoding.UTF8.GetString(request[1..])));
            _server.AddUnary<HelloRequest, HelloReply>("/test.Net/Throw",
                _ => throw new InvalidOperationException("a handler bug"));
            _server.AddUnary<HelloRequest, HelloReply>("/test.Net/RpcFail",
                _ => throw new RpcException(new Status(StatusCode.NotFound, "nope")));
            _server.AddUnary("/test.Net/AnswerThenThrow", (request, call) =>
            {
                call.Reply("ok"u8);
                throw new InvalidOperationException("after the answer");
            });
            _server.Start();
        }
        catch (Exception e) when (!LinuxRequired)
        {
            UnavailableReason = $"GrpcAsmServer unavailable ({e.GetType().Name}: {e.Message}). Set " +
                                "GRPCASM_REQUIRE_LINUX=1 to fail instead of skipping.";
        }

        return ValueTask.CompletedTask;
    }

    /// <summary>Stops and frees the server.</summary>
    /// <returns>A completed task.</returns>
    public ValueTask DisposeAsync()
    {
        _server?.Dispose();
        return ValueTask.CompletedTask;
    }

    /// <summary>Skips the calling test when the server does not run.</summary>
    /// <returns>The server's port.</returns>
    public int RequirePort()
    {
        if (UnavailableReason is not null)
        {
            Assert.Skip(UnavailableReason);
        }

        return Port;
    }

    /// <summary>A port free right now on 127.0.0.1 (bound, read, released).</summary>
    /// <returns>The port.</returns>
    public static int FreePort()
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        int port = ((IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();
        return port;
    }
}
