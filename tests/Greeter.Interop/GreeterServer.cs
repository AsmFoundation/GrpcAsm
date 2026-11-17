using DotNet.Testcontainers.Builders;
using DotNet.Testcontainers.Configurations;
using DotNet.Testcontainers.Containers;
using Xunit;

[assembly: AssemblyFixture(typeof(GrpcAsm.Greeter.Interop.GreeterServer))]

namespace GrpcAsm.Greeter.Interop;

/// <summary>
/// One Greeter (samples/Greeter, the GrpcAsm engine's generic test service) shared by every
/// test in the assembly, running in a stock Linux container started through Testcontainers.
/// </summary>
/// <remarks>
/// <para>
/// The container is <see cref="Image"/> (default <see cref="DefaultImage"/>, glibc 2.36: the
/// Greeter is a dynamically linked glibc 2.34+ executable built by AsmFoundation.Sdk) with this
/// tree's freshly built <c>greeter</c> copied in before it starts. There is no image to build
/// and none can be stale: the tests always exercise the engine the solution just built.
/// </para>
/// <para>
/// Without Docker or the binary, the tests are skipped with the reason, unless
/// <c>GRPCASM_REQUIRE_DOCKER=1</c>, which turns that into a failure so that CI can never pass
/// by skipping the tests that matter.
/// </para>
/// </remarks>
public sealed class GreeterServer : IAsyncLifetime
{
    /// <summary>The image used when <c>GREETER_IMAGE</c> is not set.</summary>
    public const string DefaultImage = "debian:bookworm-slim";

    /// <summary>The port the Greeter listens on inside the container.</summary>
    public const int ContainerPort = 50051;

    private IContainer? _container;

    /// <summary>The server's address (h2c), set once the container is listening.</summary>
    public Uri? Address { get; private set; }

    /// <summary>Why the server could not be started, or null when it runs.</summary>
    public string? UnavailableReason { get; private set; }

    /// <summary>The base image the Greeter runs in.</summary>
    public static string Image =>
        Environment.GetEnvironmentVariable("GREETER_IMAGE") is { Length: > 0 } image ? image : DefaultImage;

    /// <summary>True when the tests must fail rather than skip without Docker or the binary.</summary>
    public static bool DockerRequired => Environment.GetEnvironmentVariable("GRPCASM_REQUIRE_DOCKER") == "1";

    /// <summary>Starts the shared Greeter, or records why it cannot run.</summary>
    /// <returns>A task that completes when the Greeter listens, or the failure is recorded.</returns>
    /// <exception cref="Exception">Startup failed and <see cref="DockerRequired"/> is set.</exception>
    public async ValueTask InitializeAsync()
    {
        try
        {
            string binary = LocateBinary();
            ContainerBuilder builder = new ContainerBuilder(Image)
                // Copied in before the start, with its execute bits: no bind mount, so this
                // works the same from Windows, macOS and Linux hosts.
                .WithResourceMapping(await File.ReadAllBytesAsync(binary), "/greeter/greeter", fileMode: Unix.FileMode755)
                .WithEntrypoint("/greeter/greeter")
                .WithEnvironment("GREETER_PORT", ContainerPort.ToString(System.Globalization.CultureInfo.InvariantCulture))
                .WithEnvironment("GREETER_WORKERS", "2")
                .WithPortBinding(ContainerPort, assignRandomHostPort: true)
                // Readiness is the Greeter's own log line, written once every worker listens.
                .WithWaitStrategy(Wait.ForUnixContainer().UntilMessageIsLogged("msg=\"listening\""));
            _container = builder.Build();
            await _container.StartAsync();
            Address = new Uri($"http://{_container.Hostname}:{_container.GetMappedPublicPort(ContainerPort)}");
        }
        catch (Exception e) when (!DockerRequired)
        {
            UnavailableReason = $"Greeter unavailable ({e.GetType().Name}: {e.Message}). Build the solution, start " +
                                "Docker, or set GRPCASM_REQUIRE_DOCKER=1 to fail instead of skipping.";
        }
    }

    /// <summary>Stops and removes the container.</summary>
    /// <returns>A task that completes when the container is gone.</returns>
    public async ValueTask DisposeAsync()
    {
        if (_container is not null)
        {
            await _container.DisposeAsync();
        }
    }

    /// <summary>Skips the calling test when no server is available.</summary>
    /// <returns>The server's address.</returns>
    public Uri RequireAddress()
    {
        if (UnavailableReason is not null)
        {
            Assert.Skip(UnavailableReason);
        }

        return Address!;
    }

    /// <summary>
    /// Finds the Greeter executable: <c>GREETER_BINARY</c> when set, else
    /// <c>samples/Greeter/bin/Release/greeter</c> under the first ancestor of the test assembly
    /// that holds <c>GrpcAsm.slnx</c>.
    /// </summary>
    /// <returns>The executable's full path.</returns>
    /// <exception cref="FileNotFoundException">No such file: the solution was not built (Release).</exception>
    private static string LocateBinary()
    {
        if (Environment.GetEnvironmentVariable("GREETER_BINARY") is { Length: > 0 } configured)
        {
            return File.Exists(configured)
                ? configured
                : throw new FileNotFoundException("GREETER_BINARY does not exist", configured);
        }

        for (DirectoryInfo? dir = new(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
        {
            if (File.Exists(Path.Combine(dir.FullName, "GrpcAsm.slnx")))
            {
                string candidate = Path.Combine(dir.FullName, "samples", "Greeter", "bin", "Release", "greeter");
                return File.Exists(candidate)
                    ? candidate
                    : throw new FileNotFoundException("build first: dotnet build GrpcAsm.slnx -c Release", candidate);
            }
        }

        throw new FileNotFoundException("GrpcAsm.slnx not found above the test assembly; set GREETER_BINARY");
    }
}
