using Grpc.Core;

namespace GrpcAsm.Samples;

/// <summary>
/// shop.Orders: prices an order. A service with a realistic request (a ~1 KiB record of strings,
/// a nested address and repeated lines) and a little business logic, as a contrast to the
/// Greeter's one short string: here parsing and building messages take a real share of each
/// call, and that work is Google.Protobuf's on both sample servers.
/// </summary>
/// <remarks>
/// The rules: an order has an <c>order_id</c> and at least one line; every line has a quantity
/// of 1 or more and a price of 0 or more; the coupon "SAVE10" takes 10% off the subtotal
/// (rounded down to the cent). A broken rule is INVALID_ARGUMENT with the reason, thrown as an
/// <see cref="RpcException"/>, which both servers send as that status. Synchronous, as GrpcAsm
/// requires today (see <see cref="GreeterService"/>).
/// </remarks>
public sealed class OrdersService : Orders.OrdersBase
{
    /// <summary>The coupon that takes 10% off.</summary>
    public const string TenPercentCoupon = "SAVE10";

    /// <summary>Prices <paramref name="request"/>: subtotal, discount, total and item count.</summary>
    /// <param name="request">The order.</param>
    /// <param name="context">The call's context (unused).</param>
    /// <returns>A completed task with the receipt.</returns>
    /// <exception cref="RpcException">INVALID_ARGUMENT: a rule is broken, or the amounts overflow 64 bits.</exception>
    public override Task<Receipt> Place(Order request, ServerCallContext context)
    {
        if (request.OrderId.Length == 0)
        {
            throw Invalid("order_id is required");
        }

        if (request.Lines.Count == 0)
        {
            throw Invalid("an order has at least one line");
        }

        long subtotal = 0;
        uint items = 0;
        try
        {
            // checked: a hostile order can name quantities and prices whose product or sum does
            // not fit; that is the caller's error, not a server fault (INTERNAL).
            foreach (Line line in request.Lines)
            {
                if (line.Quantity == 0)
                {
                    throw Invalid($"line {line.Sku}: the quantity is 0");
                }

                if (line.UnitPriceCents < 0)
                {
                    throw Invalid($"line {line.Sku}: the price is negative");
                }

                subtotal = checked(subtotal + line.UnitPriceCents * line.Quantity);
                items = checked(items + line.Quantity);
            }
        }
        catch (OverflowException)
        {
            throw Invalid("the order's amounts overflow");
        }

        long discount = request.Coupon == TenPercentCoupon ? subtotal / 10 : 0;
        return Task.FromResult(new Receipt
        {
            OrderId = request.OrderId,
            SubtotalCents = subtotal,
            DiscountCents = discount,
            TotalCents = subtotal - discount,
            Items = items,
            Currency = request.Currency,
            Status = "ACCEPTED",
        });
    }

    /// <summary>An INVALID_ARGUMENT error with its reason.</summary>
    /// <param name="reason">What is wrong with the order.</param>
    /// <returns>The exception to throw.</returns>
    private static RpcException Invalid(string reason) => new(new Status(StatusCode.InvalidArgument, reason));
}
