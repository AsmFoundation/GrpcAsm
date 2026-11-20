namespace GrpcAsm.Samples;

/// <summary>
/// The order benchmarks/endtoend/2026-11-20-aspnet sends to shop.Orders/Place, and that the tests
/// check the receipt of: one fixed, realistic order of 12 lines, about 1 KiB serialized.
/// </summary>
/// <remarks>
/// Fixed on purpose: the benchmark's request file is generated from it, the tests assert its
/// receipt, and a change here changes both (the tests name the expected amounts, so an edit that
/// moves them fails loudly instead of silently changing the workload).
/// </remarks>
public static class SampleOrders
{
    /// <summary>The 12 lines' titles: product names of the length a storefront sends.</summary>
    private static readonly string[] Titles =
    [
        "Mechanical keyboard, brown switches, ISO layout",
        "USB-C to USB-C cable, braided, 2 m, 100 W",
        "27-inch monitor arm, gas spring, VESA 75/100",
        "Noise-cancelling headphones, over-ear, black",
        "Laptop stand, aluminium, adjustable height",
        "Wireless mouse, 4,000 dpi, silent buttons",
        "Desk mat, felt, 90 x 40 cm, charcoal grey",
        "Webcam, 1080p, autofocus, privacy shutter",
        "USB hub, 7 ports, powered, aluminium case",
        "Cable management tray, under-desk, steel",
        "LED desk lamp, dimmable, warm to cool white",
        "Ergonomic footrest, adjustable tilt, grey",
    ];

    /// <summary>Builds the benchmark's order (a new instance each time).</summary>
    /// <returns>
    /// Order "ord-2026-11-20-000001", 12 lines, coupon "SAVE10". Its receipt: subtotal 222,976
    /// cents, discount 22,297, total 200,679, 24 items (GrpcAsm.Net.Tests asserts these).
    /// </returns>
    public static Order Benchmark()
    {
        var order = new Order
        {
            OrderId = "ord-2026-11-20-000001",
            CustomerId = "cus-7f3a9c21-58b4-4c1e-9d2a",
            Currency = "EUR",
            Shipping = new Address
            {
                Name = "Ada Lovelace",
                Street = "12 Analytical Engine Way, Flat 3",
                City = "London",
                Region = "Greater London",
                PostalCode = "NW1 6XE",
                Country = "GB",
            },
            Coupon = OrdersService.TenPercentCoupon,
            Note = "Please leave the parcel with the concierge if nobody answers the door.",
            CreatedUnixMs = 1_795_104_000_000,
        };
        for (int i = 0; i < Titles.Length; i++)
        {
            order.Lines.Add(new Line
            {
                Sku = $"SKU-{10_001 + i * 37:D6}",
                Title = Titles[i],
                Quantity = (uint)(i % 3 + 1),
                UnitPriceCents = 1_999 + i * 1_250,
            });
        }

        return order;
    }
}
