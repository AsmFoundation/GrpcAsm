using System.Runtime.InteropServices;

namespace GrpcAsm.Net;

/// <summary>
/// The C ABI of <c>libgrpcasm.so</c> (<c>include/grpcasm.h</c>, version <c>GRPCASM_0.1</c>),
/// one declaration per function. Everything public in this assembly goes through here.
/// </summary>
/// <remarks>
/// <para>
/// Every type is blittable (pointers, <see cref="nint"/>, integers and sequential structs of
/// them), so no marshalling code runs on a call: the source generator emits the call itself.
/// Strings are passed as NUL-terminated UTF-8 the caller has encoded, never through the
/// generator's per-call allocation.
/// </para>
/// <para>
/// Results follow the header: 0 or a count on success, a negative errno on failure. The
/// public classes turn them into exceptions.
/// </para>
/// </remarks>
internal static unsafe partial class Native
{
    /// <summary>
    /// The library's name: <c>libgrpcasm.so</c>, which the .NET host finds through the
    /// application's deps.json (runtimes/linux-x64/native/ in a portable build) or next to the
    /// application (a build for linux-x64).
    /// </summary>
    private const string Library = "grpcasm";

    /// <summary>EINVAL: an argument is out of range.</summary>
    internal const int EINVAL = 22;

    /// <summary>EBUSY: a server already runs in this process (or this one already started).</summary>
    internal const int EBUSY = 16;

    /// <summary>EALREADY: the call has been answered.</summary>
    internal const int EALREADY = 114;

    /// <summary>EADDRINUSE: another process serves the port.</summary>
    internal const int EADDRINUSE = 98;

    /// <summary>EMSGSIZE: a message of 4 GiB or more.</summary>
    internal const int EMSGSIZE = 90;

    /// <summary>ESHUTDOWN: the connection takes no new calls (GOAWAY, or out of stream ids).</summary>
    internal const int ESHUTDOWN = 108;

    /// <summary>
    /// The ABI this assembly is written against, (major &lt;&lt; 8) | minor: grpcasm.h's
    /// GRPCASM_VERSION_MAJOR and GRPCASM_VERSION_MINOR. Raise it with the header.
    /// </summary>
    internal const uint AbiMajorMinor = (0 << 8) | 1;

    /// <summary>Set once a loaded library passed <see cref="RequireCompatibleLibrary"/>.</summary>
    private static volatile bool s_libraryChecked;

    /// <summary>
    /// Throws unless the loaded <c>libgrpcasm.so</c> has the major and minor version this
    /// assembly is written against. Called before the first server or client is created.
    /// </summary>
    /// <exception cref="DllNotFoundException">No libgrpcasm.so could be loaded (not Linux x64, or not deployed with the application).</exception>
    /// <exception cref="BadImageFormatException">The loaded library is another version of the ABI.</exception>
    /// <remarks>
    /// Why: P/Invoke looks symbols up by name, without the ELF version (GRPCASM_0.1) that the C
    /// linker would check, so a library of another ABI on the search path would bind silently
    /// and misread every struct. .NET reports a native library of the wrong architecture as
    /// <see cref="BadImageFormatException"/>; a wrong ABI is the same mistake one level up.
    /// Races are harmless: two threads may both check, with the same answer.
    /// </remarks>
    internal static void RequireCompatibleLibrary()
    {
        if (s_libraryChecked)
        {
            return;
        }

        uint version = Version();
        if (version >> 8 != AbiMajorMinor)
        {
            throw new BadImageFormatException(
                $"libgrpcasm.so {version >> 16}.{(version >> 8) & 0xFF}.{version & 0xFF} is loaded; " +
                $"GrpcAsm.Net needs the {AbiMajorMinor >> 8}.{AbiMajorMinor & 0xFF} ABI");
        }

        s_libraryChecked = true;
    }

    /// <summary>The library's version, (major &lt;&lt; 16) | (minor &lt;&lt; 8) | patch.</summary>
    /// <returns>The version number.</returns>
    [LibraryImport(Library, EntryPoint = "grpcasm_version")]
    internal static partial uint Version();

    /// <summary>
    /// grpcasm_pb_bytes: the last occurrence of a length-delimited field of a protobuf message,
    /// zero-copy, after the whole message has been checked.
    /// </summary>
    /// <param name="message">The message (may be null when the length is 0).</param>
    /// <param name="length">Its length.</param>
    /// <param name="field">The field number, 1..2^29-1 (the caller checks the upper bound).</param>
    /// <param name="value">Receives a pointer into the message, or null when the field is absent.</param>
    /// <param name="valueLength">Receives the field's length (0 when absent).</param>
    /// <returns>1 (present), 0 (absent) or -EINVAL (malformed message).</returns>
    /// <remarks>
    /// No <see cref="SuppressGCTransitionAttribute"/>, unlike the client's two leaf calls: the
    /// scan is linear in the message, which may be megabytes of tiny fields, and a thread in
    /// cooperative mode that long would hold up every garbage collection.
    /// </remarks>
    [LibraryImport(Library, EntryPoint = "grpcasm_pb_bytes")]
    internal static partial int PbBytes(byte* message, nuint length, uint field, byte** value, nuint* valueLength);

    /// <summary>grpcasm_server_new: creates a server from options.</summary>
    /// <param name="options">The options (size-versioned), or null.</param>
    /// <param name="server">Receives the server.</param>
    /// <returns>0, -EINVAL or -ENOMEM.</returns>
    [LibraryImport(Library, EntryPoint = "grpcasm_server_new")]
    internal static partial int ServerNew(ServerOptions* options, nint* server);

    /// <summary>grpcasm_server_add_unary: registers a method before the start.</summary>
    /// <param name="server">The server.</param>
    /// <param name="path">The method's path, NUL-terminated UTF-8.</param>
    /// <param name="handler">The handler: (context, call, request, length) -&gt; 0 or negative.</param>
    /// <param name="context">Passed to the handler as is.</param>
    /// <returns>0, -EINVAL, -EEXIST, -ENOSPC or -EBUSY.</returns>
    [LibraryImport(Library, EntryPoint = "grpcasm_server_add_unary")]
    internal static partial int ServerAddUnary(nint server, byte* path,
        delegate* unmanaged<nint, nint, byte*, nuint, int> handler, nint context);

    /// <summary>grpcasm_server_start: starts the server's workers.</summary>
    /// <param name="server">The server.</param>
    /// <returns>0, -EBUSY, -EADDRINUSE or -EIO.</returns>
    [LibraryImport(Library, EntryPoint = "grpcasm_server_start")]
    internal static partial int ServerStart(nint server);

    /// <summary>grpcasm_server_stop: drains and stops a started server.</summary>
    /// <param name="server">The server.</param>
    /// <param name="totals">Receives connections, requests and errors, or null.</param>
    [LibraryImport(Library, EntryPoint = "grpcasm_server_stop")]
    internal static partial void ServerStop(nint server, ulong* totals);

    /// <summary>grpcasm_server_free: frees a server, stopping it first if it runs.</summary>
    /// <param name="server">The server, or 0.</param>
    [LibraryImport(Library, EntryPoint = "grpcasm_server_free")]
    internal static partial void ServerFree(nint server);

    /// <summary>grpcasm_call_reply: answers a call with one message and status OK.</summary>
    /// <param name="call">The call (valid only during its handler).</param>
    /// <param name="message">The message's bytes (copied before the return).</param>
    /// <param name="length">Their number.</param>
    /// <returns>0, -EALREADY, -EMSGSIZE or -1 (out of memory).</returns>
    [LibraryImport(Library, EntryPoint = "grpcasm_call_reply")]
    internal static partial int CallReply(nint call, byte* message, nuint length);

    /// <summary>grpcasm_call_fail: answers a call with an error status.</summary>
    /// <param name="call">The call.</param>
    /// <param name="status">The gRPC status, 1..16.</param>
    /// <param name="message">NUL-terminated UTF-8 text, or null.</param>
    /// <returns>0, -EALREADY, -EINVAL or -1 (out of memory).</returns>
    [LibraryImport(Library, EntryPoint = "grpcasm_call_fail")]
    internal static partial int CallFail(nint call, int status, byte* message);

    /// <summary>grpcasm_client_new: a client without a socket (bytes in, bytes out).</summary>
    /// <param name="options">The options (size-versioned), or null.</param>
    /// <param name="client">Receives the client.</param>
    /// <returns>0, -EINVAL or -ENOMEM.</returns>
    [LibraryImport(Library, EntryPoint = "grpcasm_client_new")]
    internal static partial int ClientNew(ClientOptions* options, nint* client);

    /// <summary>grpcasm_client_free: completes every call CANCELLED, then frees the client.</summary>
    /// <param name="client">The client, or 0.</param>
    [LibraryImport(Library, EntryPoint = "grpcasm_client_free")]
    internal static partial void ClientFree(nint client);

    /// <summary>grpcasm_client_method: registers a method's path.</summary>
    /// <param name="client">The client.</param>
    /// <param name="path">NUL-terminated UTF-8 path.</param>
    /// <returns>The handle, or -EINVAL / -ENOMEM.</returns>
    [LibraryImport(Library, EntryPoint = "grpcasm_client_method")]
    internal static partial int ClientMethod(nint client, byte* path);

    /// <summary>grpcasm_client_call: issues a unary call.</summary>
    /// <param name="client">The client.</param>
    /// <param name="method">A method handle.</param>
    /// <param name="request">The request message's bytes (copied).</param>
    /// <param name="length">Their number.</param>
    /// <param name="done">The completion: (context, status, message, length, response, length).</param>
    /// <param name="context">Passed to done.</param>
    /// <returns>0 (done will run once), or a negative errno (done never runs).</returns>
    [LibraryImport(Library, EntryPoint = "grpcasm_client_call")]
    internal static partial int ClientCall(nint client, int method, byte* request, nuint length,
        delegate* unmanaged<nint, int, byte*, nuint, byte*, nuint, void> done, nint context);

    /// <summary>grpcasm_client_input: processes bytes received from the server.</summary>
    /// <param name="client">The client.</param>
    /// <param name="data">The bytes (read only during the call).</param>
    /// <param name="length">Their number.</param>
    /// <returns>Calls completed, or a negative errno.</returns>
    [LibraryImport(Library, EntryPoint = "grpcasm_client_input")]
    internal static partial int ClientInput(nint client, byte* data, nuint length);

    /// <summary>grpcasm_client_output: the bytes waiting to be sent.</summary>
    /// <param name="client">The client.</param>
    /// <param name="data">Receives where they are.</param>
    /// <returns>Their number.</returns>
    /// <remarks>
    /// <see cref="SuppressGCTransitionAttribute"/>: a leaf that reads two fields, for which the
    /// GC mode switch would cost more than the call.
    /// </remarks>
    [LibraryImport(Library, EntryPoint = "grpcasm_client_output")]
    [SuppressGCTransition]
    internal static partial nuint ClientOutput(nint client, byte** data);

    /// <summary>grpcasm_client_consume: reports that bytes of the output were sent.</summary>
    /// <param name="client">The client.</param>
    /// <param name="length">How many.</param>
    /// <remarks>
    /// <see cref="SuppressGCTransitionAttribute"/>: a leaf that writes two fields.
    /// </remarks>
    [LibraryImport(Library, EntryPoint = "grpcasm_client_consume")]
    [SuppressGCTransition]
    internal static partial void ClientConsume(nint client, nuint length);
}

/// <summary><c>grpcasm_options</c> (grpcasm.h): every field 32-bit, zero = the default.</summary>
[StructLayout(LayoutKind.Sequential)]
internal struct ServerOptions
{
    /// <summary>sizeof(grpcasm_options) as this struct has it.</summary>
    public uint Size;

    /// <summary>TCP port.</summary>
    public uint Port;

    /// <summary>Worker threads.</summary>
    public uint Workers;

    /// <summary>SETTINGS_MAX_CONCURRENT_STREAMS.</summary>
    public uint MaxStreams;

    /// <summary>Connections per worker.</summary>
    public uint MaxConnections;

    /// <summary>Idle timeout in seconds; uint.MaxValue = never.</summary>
    public uint IdleTimeoutSeconds;

    /// <summary>Drain deadline in seconds.</summary>
    public uint ShutdownGraceSeconds;

    /// <summary>Request bytes one connection may buffer, MiB.</summary>
    public uint ConnectionBufferMb;

    /// <summary>Largest request message, bytes.</summary>
    public uint MaxMessageBytes;
}

/// <summary><c>grpcasm_client_options</c> (grpcasm.h): zero = the default.</summary>
[StructLayout(LayoutKind.Sequential)]
internal unsafe struct ClientOptions
{
    /// <summary>sizeof(grpcasm_client_options) as this struct has it.</summary>
    public uint Size;

    /// <summary>Largest response message, bytes.</summary>
    public uint MaxResponseBytes;

    /// <summary>Calls in flight on the connection.</summary>
    public uint MaxConcurrentCalls;

    /// <summary>Connect timeout (socket mode only; unused by this assembly).</summary>
    public uint ConnectTimeoutMs;

    /// <summary>The :authority, NUL-terminated UTF-8, or null.</summary>
    public byte* Authority;
}
