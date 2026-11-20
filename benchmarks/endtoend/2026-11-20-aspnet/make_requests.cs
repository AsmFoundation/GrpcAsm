#:project ../../../samples/Greeter.Service/Greeter.Service.csproj
// =============================================================================
// make_requests.cs — the benchmark's request bodies and the reply sizes its checks expect,
// built from the sample's own types, so they cannot drift from what the servers parse.
//
// Usage: dotnet run make_requests.cs -- OUTPUT_FOLDER   (run.sh does)
//
// Writes, per workload (hello = helloworld.Greeter/SayHello, order = shop.Orders/Place):
//   req-<name>.bin    the gRPC-framed request: flag 0, the length (big-endian), the message;
//                     h2load sends it as each call's body (-d)
//   reply-<name>.size the framed reply's size in bytes. h2load counts every DATA byte it
//                     receives, so bench.sh checks that the data bytes equal the calls times
//                     this size: an error answer carries no message, so a single failed call
//                     anywhere makes the count wrong, on servers that count nothing
//                     themselves (ASP.NET Core) as on those that do.
// The hello request is SayHello("world"), as in the earlier Greeter benchmarks; the order
// request is SampleOrders.Benchmark(), and its expected reply is what OrdersService computes.
// =============================================================================
using System.Buffers.Binary;
using System.Globalization;
using Google.Protobuf;
using GrpcAsm.Samples;

string folder = args.Length == 1 ? args[0] : throw new ArgumentException("usage: make_requests.cs OUTPUT_FOLDER");
Directory.CreateDirectory(folder);

Write("hello", new HelloRequest { Name = "world" }, new HelloReply { Message = "Hello world" });

Order order = SampleOrders.Benchmark();
// The context is unused by OrdersService; the reply is exactly what both servers send.
Receipt receipt = new OrdersService().Place(order, null!).GetAwaiter().GetResult();
Write("order", order, receipt);
return 0;

// Writes one workload's request and expected reply size, and reports them.
void Write(string name, IMessage request, IMessage reply)
{
    byte[] message = request.ToByteArray();
    byte[] framed = new byte[5 + message.Length];
    BinaryPrimitives.WriteUInt32BigEndian(framed.AsSpan(1), (uint)message.Length);
    message.CopyTo(framed, 5);
    File.WriteAllBytes(Path.Combine(folder, $"req-{name}.bin"), framed);
    int replySize = 5 + reply.CalculateSize();
    File.WriteAllText(Path.Combine(folder, $"reply-{name}.size"), replySize.ToString(CultureInfo.InvariantCulture));
    Console.WriteLine($"{name}: request {framed.Length} bytes framed ({message.Length} message), reply {replySize} bytes framed");
}
