using System.Net;
using GrpcAsm.Samples;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Server.Kestrel.Core;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Xunit;

[assembly: AssemblyFixture(typeof(GrpcAsm.Net.Tests.KestrelServer))]

namespace GrpcAsm.Net.Tests;

/// <summary>
/// ASP.NET Core gRPC (Kestrel and grpc-dotnet) in the test process, hosting the same service
/// classes as <see cref="NetServer"/>'s GrpcAsmServer: samples/Greeter.Service's
/// <see cref="GreeterService"/> and <see cref="OrdersService"/>, and the test's
/// <see cref="BinderService"/>. <see cref="ParityTests"/> calls both servers and compares.
/// </summary>
/// <remarks>
/// Kestrel runs on any OS, but the comparison needs both servers: the tests that use this
/// fixture skip with GrpcAsmServer's reason off Linux (see <see cref="NetServer.RequirePort"/>).
/// </remarks>
public sealed class KestrelServer : IAsyncLifetime
{
    /// <summary>The running application, or null before start.</summary>
    private WebApplication? _app;

    /// <summary>The port Kestrel listens on (127.0.0.1, h2c).</summary>
    public int Port { get; private set; }

    /// <summary>Starts Kestrel with the three services.</summary>
    /// <returns>A task that completes when Kestrel listens.</returns>
    /// <exception cref="IOException">Kestrel could not bind its port.</exception>
    public async ValueTask InitializeAsync()
    {
        Port = NetServer.FreePort();
        WebApplicationBuilder builder = WebApplication.CreateSlimBuilder();
        builder.Logging.ClearProviders();
        builder.WebHost.ConfigureKestrel(k => k.Listen(IPAddress.Loopback, Port, l => l.Protocols = HttpProtocols.Http2));
        builder.Services.AddGrpc();
        _app = builder.Build();
        _app.MapGrpcService<GreeterService>();
        _app.MapGrpcService<OrdersService>();
        _app.MapGrpcService<BinderService>();
        await _app.StartAsync();
    }

    /// <summary>Stops Kestrel.</summary>
    /// <returns>A task that completes when it has stopped.</returns>
    public async ValueTask DisposeAsync()
    {
        if (_app is not null)
        {
            await _app.DisposeAsync();
        }
    }
}
