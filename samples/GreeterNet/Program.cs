// =============================================================================
// GreeterNet: C# gRPC services on GrpcAsmServer, whose engine is assembly.
//
// The engine (libgrpcasm.so) does HTTP/2, HPACK, the gRPC rules, the health service and the
// event loops; the C# handlers run inline on the worker thread that read the request, through
// GrpcAsm.Net's reverse call. By default the services are the classes of samples/Greeter.Service,
// the same ones samples/GreeterAspNet hosts on ASP.NET Core, bound with one line each:
//
//     Greeter.BindService(server.ServiceBinder, new GreeterService());
//     Orders.BindService(server.ServiceBinder, new OrdersService());
//
// SayHello answers as samples/Greeter (NASM) and samples/GreeterC (C) do, with the same
// settings, log lines and exit codes, so tests/greeter/run.sh checks all three
// (tests/greeter_net.sh runs it on this one, once per mode). One input differs, by protobuf's
// rules: a name that is not valid UTF-8 (see SayHello.Typed).
//
// Settings: GREETER_PORT (1..65535, default 50051) and GREETER_WORKERS (1..256, default 1),
// parsed strictly as the other Greeters parse them; GREETER_MODE picks how SayHello is written:
//   service (default) GreeterService, a grpc-dotnet class, through GrpcAsmServer.ServiceBinder:
//           its marshallers, a Task, a ServerCallContext per call
//   typed   a Func<HelloRequest, HelloReply>: HelloRequest parsed, HelloReply serialized on
//           the stack, no Task or context
//   raw     the request's bytes: GrpcAsmProtobuf finds field 1 in place, the reply is framed
//           by hand, the name echoed as bytes; what a hand-tuned .NET handler costs
// In the first two, a name that is not valid UTF-8 is refused (protobuf's string rule), as is a
// request that is not a HelloRequest: typed answers INVALID_ARGUMENT "malformed request message"
// (the Greeters' answer); service answers as ASP.NET Core does, UNKNOWN "Exception was thrown by
// handler." (tests/greeter/run.sh expects each).
// shop.Orders/Place is OrdersService through the binder in every mode.
// An invalid setting is logged with its name and the process exits 2; a server that cannot
// start exits 1 (the library logs why: a port in use, a worker that failed).
// =============================================================================
using System.Buffers;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using Grpc.Core;
using GrpcAsm.Net;
using GrpcAsm.Samples;

if (!Settings.TryRead("GREETER_PORT", 1, 65535, 50051, out uint port))
{
    Log.Line("ERROR", "msg=\"invalid setting\" name=GREETER_PORT");
    return 2;
}

if (!Settings.TryRead("GREETER_WORKERS", 1, 256, 1, out uint workers))
{
    Log.Line("ERROR", "msg=\"invalid setting\" name=GREETER_WORKERS");
    return 2;
}

string mode = Environment.GetEnvironmentVariable("GREETER_MODE") ?? "service";
if (mode is not ("service" or "typed" or "raw"))
{
    Log.Line("ERROR", "msg=\"invalid setting\" name=GREETER_MODE");
    return 2;
}

Log.Line("INFO", $"msg=\"starting\" service=helloworld.Greeter port={port} workers={workers} mode={mode}");

GrpcAsmServer server;
try
{
    server = new GrpcAsmServer(new GrpcAsmServerOptions { Port = (int)port, Workers = (int)workers });
}
catch (Exception e) when (e is DllNotFoundException or BadImageFormatException or OutOfMemoryException)
{
    // DllNotFound: not Linux x64, or libgrpcasm.so is not next to the program;
    // BadImageFormat: a libgrpcasm.so of another ABI version.
    Log.Line("ERROR", $"msg=\"cannot create the server\" error=\"{e.Message}\"");
    return 1;
}

using (server)
{
    switch (mode)
    {
        case "raw":
            server.AddUnary("/helloworld.Greeter/SayHello", SayHello.Raw);
            break;
        case "typed":
            server.AddUnary<HelloRequest, HelloReply>("/helloworld.Greeter/SayHello", SayHello.Typed);
            break;
        default:
            // The grpc-dotnet class, unchanged: what samples/GreeterAspNet maps with
            // app.MapGrpcService<GreeterService>().
            Greeter.BindService(server.ServiceBinder, new GreeterService());
            break;
    }

    Orders.BindService(server.ServiceBinder, new OrdersService());

    // SIGTERM and SIGINT stop the server, as grpcasm_server_run does for the C Greeter: the
    // registrations cancel the runtime's default (exit at once) and release the main thread,
    // which drains the server through Stop. They exist before Start, so a signal that arrives
    // while the workers start is not lost.
    using var stop = new ManualResetEventSlim();
    int signal = 0;
    void OnSignal(PosixSignalContext context)
    {
        context.Cancel = true;
        Interlocked.CompareExchange(ref signal, context.Signal == PosixSignal.SIGTERM ? 15 : 2, 0);
        stop.Set();
    }

    using PosixSignalRegistration onTerm = PosixSignalRegistration.Create(PosixSignal.SIGTERM, OnSignal);
    using PosixSignalRegistration onInt = PosixSignalRegistration.Create(PosixSignal.SIGINT, OnSignal);
    try
    {
        server.Start(); // logs "listening"
    }
    catch (Exception e) when (e is SocketException or IOException)
    {
        // The library logged the reason already (the port in use, a worker that failed).
        return 1;
    }

    stop.Wait();
    Log.Line("INFO", $"msg=\"shutdown requested\" signal={Volatile.Read(ref signal)}");
    GrpcAsmServerTotals totals = server.Stop();
    Log.Line("INFO", $"msg=\"stopped\" connections={totals.Connections} requests={totals.Requests} errors={totals.Errors}");
}

return 0;

/// <summary>
/// The two SayHello handlers written against GrpcAsm.Net's own API, for comparison with
/// GreeterService (the default): HelloReply{message = "Hello " + HelloRequest.name}.
/// </summary>
internal static class SayHello
{
    /// <summary>The typed handler: a plain function of the message, no Task or context.</summary>
    /// <param name="request">The parsed request.</param>
    /// <returns>The reply; GrpcAsmServer serializes it on the stack.</returns>
    /// <remarks>
    /// Protobuf's string semantics, the one way this Greeter differs from the others: a name
    /// that is not valid UTF-8 makes Google.Protobuf refuse the request
    /// (InvalidProtocolBufferException), which GrpcAsmServer answers INVALID_ARGUMENT
    /// "malformed request message" before this runs (checked: 0A 02 FF FE). The raw handler,
    /// like the assembly and C Greeters, treats the name as bytes and echoes them.
    /// </remarks>
    public static HelloReply Typed(HelloRequest request) => new() { Message = "Hello " + request.Name };

    /// <summary>
    /// The raw handler: field 1 found in place in the request (no allocation, no UTF-8
    /// decoding), the reply framed by hand on the stack.
    /// </summary>
    /// <param name="request">The HelloRequest's bytes, valid during this call.</param>
    /// <param name="call">The call, answered exactly once here.</param>
    /// <remarks>
    /// The reply is tag 0x0A (field 1, length-delimited), the varint length of
    /// "Hello " + name, "Hello ", then the name: the bytes the other Greeters send. Up to 1 KiB
    /// it is built on the stack; a larger one (names reach 4 MiB, the default message limit)
    /// in a rented buffer, since stackalloc of an attacker-chosen size could overflow the
    /// worker's stack.
    /// </remarks>
    public static void Raw(ReadOnlySpan<byte> request, GrpcAsmCall call)
    {
        if (!GrpcAsmProtobuf.TryGetBytes(request, 1, out ReadOnlySpan<byte> name))
        {
            call.Fail(StatusCode.InvalidArgument, "malformed request message");
            return;
        }

        int messageLength = 6 + name.Length;
        int size = 1 + VarintSize((uint)messageLength) + messageLength;
        byte[]? rented = size > 1024 ? ArrayPool<byte>.Shared.Rent(size) : null;
        try
        {
            Span<byte> reply = rented is null ? stackalloc byte[size] : rented.AsSpan(0, size);
            reply[0] = 0x0A;
            int at = 1;
            for (uint v = (uint)messageLength; ; v >>= 7)
            {
                if (v < 0x80)
                {
                    reply[at++] = (byte)v;
                    break;
                }

                reply[at++] = (byte)(v | 0x80);
            }

            "Hello "u8.CopyTo(reply[at..]);
            name.CopyTo(reply[(at + 6)..]);
            call.Reply(reply);
        }
        finally
        {
            if (rented is not null)
            {
                ArrayPool<byte>.Shared.Return(rented);
            }
        }
    }

    /// <summary>The bytes of a value's base-128 varint.</summary>
    /// <param name="value">The value.</param>
    /// <returns>1 to 5.</returns>
    private static int VarintSize(uint value) =>
        value < 1u << 7 ? 1 : value < 1u << 14 ? 2 : value < 1u << 21 ? 3 : value < 1u << 28 ? 4 : 5;
}

/// <summary>The Greeters' settings: strict decimal environment variables.</summary>
internal static class Settings
{
    /// <summary>
    /// Reads a setting as the other Greeters do: digits only (no sign, no whitespace), at most
    /// 19 of them, within [min, max]; unset means the default; set but empty is invalid.
    /// </summary>
    /// <param name="name">The environment variable.</param>
    /// <param name="min">The smallest value accepted.</param>
    /// <param name="max">The largest value accepted.</param>
    /// <param name="fallback">The value when the variable is unset.</param>
    /// <param name="value">Receives the value (0 when invalid).</param>
    /// <returns>False when the variable is set but invalid.</returns>
    /// <remarks>
    /// Not <see cref="uint.TryParse(string?, out uint)"/>: it accepts a sign, surrounding
    /// whitespace and other digit sets, which the Greeters' suite refuses ("abc", "", "0",
    /// "65536" are the cases it checks).
    /// </remarks>
    public static bool TryRead(string name, uint min, uint max, uint fallback, out uint value)
    {
        value = 0;
        string? text = Environment.GetEnvironmentVariable(name);
        if (text is null)
        {
            value = fallback;
            return true;
        }

        if (text.Length is 0 or > 19) // 19 decimal digits never overflow a ulong
        {
            return false;
        }

        ulong v = 0;
        foreach (char c in text)
        {
            if (c is < '0' or > '9')
            {
                return false;
            }

            v = v * 10 + (uint)(c - '0');
        }

        if (v < min || v > max)
        {
            return false;
        }

        value = (uint)v;
        return true;
    }
}

/// <summary>Log lines in the engine's format, "ts=&lt;seconds&gt;.&lt;ms&gt; level=&lt;LEVEL&gt; &lt;fields&gt;".</summary>
internal static class Log
{
    /// <summary>Standard error as a raw stream: one write(2) per line.</summary>
    private static readonly Stream Stderr = Console.OpenStandardError();

    /// <summary>The lock that keeps this process's lines whole.</summary>
    private static readonly Lock Gate = new();

    /// <summary>Writes one line to standard error.</summary>
    /// <param name="level">"INFO" or "ERROR".</param>
    /// <param name="fields">The fields, logfmt.</param>
    /// <remarks>
    /// Why one write per line: the engine writes its own lines ("listening", "port already in
    /// use") to the same descriptor with write(2) from its threads, and the suite greps the
    /// log line by line. Console.Error's writer may split a long line into several writes; one
    /// buffer written once cannot interleave with the engine's lines.
    /// </remarks>
    public static void Line(string level, string fields)
    {
        long ms = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        byte[] line = Encoding.UTF8.GetBytes($"ts={ms / 1000}.{ms % 1000:D3} level={level} {fields}\n");
        lock (Gate)
        {
            Stderr.Write(line);
        }
    }
}
