using Grpc.Core;

namespace GrpcAsm.Samples;

/// <summary>
/// helloworld.Greeter, written as every grpc-dotnet service is written: a class deriving from the
/// generated <see cref="Greeter.GreeterBase"/>. Both sample servers host this class as it is, so it
/// is your C# whichever engine answers the call.
/// </summary>
/// <remarks>
/// On GrpcAsm (samples/GreeterNet) the method runs inline on the assembly engine's worker thread
/// that read the request, and its <see cref="Task"/> must already be complete when it returns
/// (GrpcAsm.Net answers an unfinished one UNIMPLEMENTED: asynchronous answers are not in its C
/// ABI yet). <see cref="Task.FromResult{TResult}(TResult)"/> is complete, so this method runs the
/// same on both servers.
/// </remarks>
public sealed class GreeterService : Greeter.GreeterBase
{
    /// <summary>Answers "Hello " + the request's name.</summary>
    /// <param name="request">The request.</param>
    /// <param name="context">The call's context (unused).</param>
    /// <returns>A completed task with the reply.</returns>
    public override Task<HelloReply> SayHello(HelloRequest request, ServerCallContext context) =>
        Task.FromResult(new HelloReply { Message = "Hello " + request.Name });
}
