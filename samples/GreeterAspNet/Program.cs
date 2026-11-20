// =============================================================================
// GreeterAspNet: the C# services of samples/Greeter.Service on ASP.NET Core gRPC (Kestrel and
// grpc-dotnet): the rival samples/GreeterNet is measured against.
//
// It is the `dotnet new grpc` template's program, with the template's appsettings.json (logging
// at Information, Microsoft.AspNetCore at Warning, so no line per request), plus two things in
// code: an h2c endpoint (HTTP/2 without TLS, prior knowledge) on GREETER_PORT, and the content
// root pinned to the program's folder. Why the latter: the template's content root is the
// working directory, and started from anywhere else the app finds no appsettings.json and logs
// every request at Information. Measured in the pilot of benchmarks/endtoend/2026-11-20-aspnet:
// 8,364 calls/s on one vCPU with a log line per call, an unfair rival.
// The services are the same classes GreeterNet binds on GrpcAsm's assembly engine:
//
//     app.MapGrpcService<GreeterService>();      // GreeterNet: Greeter.BindService(server.ServiceBinder, ...)
//     app.MapGrpcService<OrdersService>();       // GreeterNet: Orders.BindService(server.ServiceBinder, ...)
//
// Settings: GREETER_PORT (1..65535, default 50051); an invalid value exits 2 with its name.
// Ready when Kestrel logs "Now listening on". SIGTERM and SIGINT stop it gracefully (exit 0).
// =============================================================================
using GrpcAsm.Samples;
using Microsoft.AspNetCore.Server.Kestrel.Core;

string? setting = Environment.GetEnvironmentVariable("GREETER_PORT");
int port = 50051;
if (setting is not null && (!int.TryParse(setting, out port) || port is < 1 or > 65535))
{
    Console.Error.WriteLine("invalid setting: GREETER_PORT (1..65535)");
    return 2;
}

// The content root is the program's folder, wherever it is started from: that is where the
// publish put appsettings.json (see the header).
WebApplicationBuilder builder = WebApplication.CreateBuilder(new WebApplicationOptions
{
    Args = args,
    ContentRootPath = AppContext.BaseDirectory,
});

// h2c on every interface: gRPC without TLS needs HTTP/2 only on the endpoint (with
// Http1AndHttp2 and no TLS, Kestrel cannot negotiate HTTP/2 and h2c clients fail).
builder.WebHost.ConfigureKestrel(kestrel =>
    kestrel.ListenAnyIP(port, listen => listen.Protocols = HttpProtocols.Http2));
builder.Services.AddGrpc();

WebApplication app = builder.Build();
app.MapGrpcService<GreeterService>();
app.MapGrpcService<OrdersService>();
app.Run();
return 0;
