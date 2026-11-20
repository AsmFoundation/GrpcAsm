using Grpc.Core;
using GrpcAsm.Net.Tests.Protos;

namespace GrpcAsm.Net.Tests;

/// <summary>
/// test.Binder: one unary method per way a grpc-dotnet method can answer (see binder.proto),
/// hosted unchanged by both servers of <see cref="ParityTests"/>.
/// </summary>
public sealed class BinderService : Binder.BinderBase
{
    /// <summary>Throws an exception that is not an RpcException.</summary>
    /// <param name="request">Unused.</param>
    /// <param name="context">Unused.</param>
    /// <returns>Never returns.</returns>
    /// <exception cref="InvalidOperationException">Always.</exception>
    public override Task<Probe> Throw(Probe request, ServerCallContext context) =>
        throw new InvalidOperationException("a handler bug");

    /// <summary>Throws an RpcException with its own status.</summary>
    /// <param name="request">Unused.</param>
    /// <param name="context">Unused.</param>
    /// <returns>Never returns.</returns>
    /// <exception cref="RpcException">Always: NOT_FOUND "nope".</exception>
    public override Task<Probe> RpcFail(Probe request, ServerCallContext context) =>
        throw new RpcException(new Status(StatusCode.NotFound, "nope"));

    /// <summary>Returns a faulted task instead of throwing.</summary>
    /// <param name="request">Unused.</param>
    /// <param name="context">Unused.</param>
    /// <returns>A task faulted with InvalidOperationException.</returns>
    public override Task<Probe> FaultedTask(Probe request, ServerCallContext context) =>
        Task.FromException<Probe>(new InvalidOperationException("a faulted task"));

    /// <summary>Returns no message.</summary>
    /// <param name="request">Unused.</param>
    /// <param name="context">Unused.</param>
    /// <returns>A completed task whose result is null.</returns>
    public override Task<Probe> NullReply(Probe request, ServerCallContext context) => Task.FromResult<Probe>(null!);

    /// <summary>Sets an error status on the context, then returns a reply anyway.</summary>
    /// <param name="request">Unused.</param>
    /// <param name="context">The context whose status is set.</param>
    /// <returns>A reply the client will not see (the status wins).</returns>
    public override Task<Probe> SetStatus(Probe request, ServerCallContext context)
    {
        context.Status = new Status(StatusCode.PermissionDenied, "set");
        return Task.FromResult(new Probe { Text = "ignored" });
    }

    /// <summary>An async method that never really awaits: complete when it returns.</summary>
    /// <param name="request">The text to echo.</param>
    /// <param name="context">Unused.</param>
    /// <returns>The echo.</returns>
    public override async Task<Probe> AsyncCompleted(Probe request, ServerCallContext context)
    {
        await Task.CompletedTask;
        return new Probe { Text = request.Text };
    }

    /// <summary>Really awaits before answering.</summary>
    /// <param name="request">The text to echo.</param>
    /// <param name="context">Unused.</param>
    /// <returns>The echo, 20 ms later.</returns>
    public override async Task<Probe> Pending(Probe request, ServerCallContext context)
    {
        await Task.Delay(20);
        return new Probe { Text = request.Text };
    }

    /// <summary>Adds a response trailer, then echoes.</summary>
    /// <param name="request">The text to echo.</param>
    /// <param name="context">The context the trailer is added to.</param>
    /// <returns>The echo.</returns>
    public override Task<Probe> Trailers(Probe request, ServerCallContext context)
    {
        context.ResponseTrailers.Add("x-test", "1");
        return Task.FromResult(new Probe { Text = request.Text });
    }

    /// <summary>Writes response headers, then echoes.</summary>
    /// <param name="request">The text to echo.</param>
    /// <param name="context">The context the headers are written through.</param>
    /// <returns>The echo.</returns>
    public override async Task<Probe> Headers(Probe request, ServerCallContext context)
    {
        await context.WriteResponseHeadersAsync(new Metadata { { "x-test", "1" } });
        return new Probe { Text = request.Text };
    }

    /// <summary>Describes the context: "method|host|peer|deadline-is-max|request-headers|cancellable".</summary>
    /// <param name="request">Unused.</param>
    /// <param name="context">The context described.</param>
    /// <returns>The description.</returns>
    public override Task<Probe> Context(Probe request, ServerCallContext context) =>
        Task.FromResult(new Probe
        {
            Text = string.Join('|', context.Method, context.Host, context.Peer,
                context.Deadline == DateTime.MaxValue, context.RequestHeaders.Count, context.CancellationToken.CanBeCanceled),
        });
}

/// <summary>test.Streaming: a client-streaming method, which GrpcAsm must refuse to bind.</summary>
public sealed class StreamingService : Streaming.StreamingBase
{
    /// <summary>Counts the probes (never runs on GrpcAsm).</summary>
    /// <param name="requestStream">The probes.</param>
    /// <param name="context">Unused.</param>
    /// <returns>The count as text.</returns>
    public override async Task<Probe> Upload(IAsyncStreamReader<Probe> requestStream, ServerCallContext context)
    {
        int n = 0;
        while (await requestStream.MoveNext())
        {
            n++;
        }

        return new Probe { Text = n.ToString(System.Globalization.CultureInfo.InvariantCulture) };
    }
}
