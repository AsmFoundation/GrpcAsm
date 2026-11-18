using Xunit;

namespace GrpcAsm.Net.Tests;

/// <summary>
/// <see cref="GrpcAsmProtobuf"/>: the engine's protobuf decoder (grpcasm_pb_bytes) through the
/// .NET wrapper, whose own work is the pinning, the offset arithmetic and the range check.
/// </summary>
/// <param name="server">
/// The shared server (assembly fixture), used only as the gate: where it cannot run, neither
/// can libgrpcasm.so, and the test is skipped (or fails, with GRPCASM_REQUIRE_LINUX=1).
/// </param>
public sealed class ProtobufTests(NetServer server)
{
    /// <summary>A present field, an absent one, and a present empty one.</summary>
    [Fact]
    public void Present_absent_and_empty_fields()
    {
        server.RequirePort();
        Assert.True(GrpcAsmProtobuf.TryGetBytes([0x0A, 0x05, .. "world"u8], 1, out ReadOnlySpan<byte> value, out bool present));
        Assert.True(present);
        Assert.Equal("world"u8, value);

        Assert.True(GrpcAsmProtobuf.TryGetBytes([], 1, out value, out present)); // an empty span pins as null
        Assert.False(present);
        Assert.True(value.IsEmpty);

        Assert.True(GrpcAsmProtobuf.TryGetBytes([0x0A, 0x00], 1, out value, out present));
        Assert.True(present); // present and empty: distinguishable through the overload
        Assert.True(value.IsEmpty);
    }

    /// <summary>
    /// Unknown fields of every skippable wire type are skipped, the last occurrence wins, the
    /// field with another wire type counts as unknown, and the slice lands at the right offset.
    /// </summary>
    [Fact]
    public void Unknown_fields_are_skipped_and_the_last_occurrence_wins()
    {
        server.RequirePort();
        byte[] message =
        [
            0x10, 0x96, 0x01,                                     // field 2, varint 150
            0x1D, 1, 2, 3, 4,                                     // field 3, fixed32
            0x21, 1, 2, 3, 4, 5, 6, 7, 8,                         // field 4, fixed64
            0x0A, 0x01, (byte)'a',                                // field 1: "a"
            0x2A, 0x02, (byte)'z', (byte)'z',                     // field 5: "zz"
            0x0A, 0x02, (byte)'b', (byte)'c',                     // field 1 again: "bc"
            0x08, 0x07,                                           // field 1 as a varint: unknown
        ];
        Assert.True(GrpcAsmProtobuf.TryGetBytes(message, 1, out ReadOnlySpan<byte> value));
        Assert.Equal("bc"u8, value);
        Assert.True(GrpcAsmProtobuf.TryGetBytes(message, 5, out value));
        Assert.Equal("zz"u8, value);
        Assert.True(GrpcAsmProtobuf.TryGetBytes(message, 2, out value, out bool present));
        Assert.False(present); // field 2 exists, but as a varint: not length-delimited

        // A 300-byte field: a two-byte length (ac 02), so the value starts at offset 3.
        byte[] large = [0x0A, 0xAC, 0x02, .. Enumerable.Repeat((byte)'a', 300)];
        Assert.True(GrpcAsmProtobuf.TryGetBytes(large, 1, out value));
        Assert.Equal(300, value.Length);
        Assert.True(value.Overlaps(large.AsSpan(3, 300), out int offset) && offset == 0); // a slice, not a copy
    }

    /// <summary>Malformed messages are refused, with an empty value.</summary>
    /// <param name="hex">
    /// The message, as hex: a length past the end (0A09), a tag with no length (0A), a varint
    /// that runs past the end (1080), a group (0B, wire type 3), wire type 7 (0F), field number
    /// 0 (0000), a fixed32 cut short (1D0102).
    /// </param>
    [Theory]
    [InlineData("0A09")]
    [InlineData("0A")]
    [InlineData("1080")]
    [InlineData("0B")]
    [InlineData("0F")]
    [InlineData("0000")]
    [InlineData("1D0102")]
    public void Malformed_messages_are_refused(string hex)
    {
        server.RequirePort();
        Assert.False(GrpcAsmProtobuf.TryGetBytes(Convert.FromHexString(hex), 1, out ReadOnlySpan<byte> value, out bool present));
        Assert.False(present);
        Assert.True(value.IsEmpty);
    }

    /// <summary>Field numbers outside 1..2^29-1 are the caller's bug: an exception, never a silent miss.</summary>
    [Fact]
    public void Field_numbers_out_of_range_throw()
    {
        server.RequirePort();
        Assert.Throws<ArgumentOutOfRangeException>(() => GrpcAsmProtobuf.TryGetBytes([], 0, out _));
        Assert.Throws<ArgumentOutOfRangeException>(() => GrpcAsmProtobuf.TryGetBytes([], -1, out _));
        Assert.Throws<ArgumentOutOfRangeException>(() => GrpcAsmProtobuf.TryGetBytes([], GrpcAsmProtobuf.MaxFieldNumber + 1, out _));
        Assert.True(GrpcAsmProtobuf.TryGetBytes([], GrpcAsmProtobuf.MaxFieldNumber, out _));
    }
}
