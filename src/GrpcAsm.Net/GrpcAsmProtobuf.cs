namespace GrpcAsm.Net;

/// <summary>
/// Zero-copy access to a protobuf message's fields with the engine's own decoder, for raw
/// handlers (<see cref="RawUnaryHandler"/>) that skip Google.Protobuf's object model.
/// </summary>
/// <remarks>
/// <para>
/// When to use: a hot method whose handler needs one or two string or bytes fields of its
/// request. The field comes back as a slice of the request, with no allocation and no UTF-8
/// decoding. The typed registration (<c>AddUnary&lt;TRequest, TResponse&gt;</c>) is the right
/// default everywhere else: it validates UTF-8 for <c>string</c> fields, which this class does
/// not.
/// </para>
/// <para>
/// The decoder is the C ABI's <c>grpcasm_pb_bytes</c>, the code the engine's health service
/// decodes with, so a raw handler accepts and refuses exactly what the engine does.
/// </para>
/// </remarks>
public static unsafe class GrpcAsmProtobuf
{
    /// <summary>The largest protobuf field number, 2^29 - 1.</summary>
    public const int MaxFieldNumber = (1 << 29) - 1;

    /// <summary>
    /// Finds a length-delimited field (string, bytes or an embedded message) of a message, once
    /// the whole message has been checked.
    /// </summary>
    /// <param name="message">The message: protobuf bytes, such as a raw handler's request.</param>
    /// <param name="field">The field number, 1..<see cref="MaxFieldNumber"/>.</param>
    /// <param name="value">
    /// The field's bytes, a slice of <paramref name="message"/> (valid as long as it is), or
    /// empty when the field is absent or the message is malformed.
    /// </param>
    /// <returns>
    /// True when the message is well-formed, whether the field is present or not (proto3: an
    /// absent string or bytes field is the empty one). False when the message is malformed;
    /// a handler then answers INVALID_ARGUMENT.
    /// </returns>
    /// <exception cref="ArgumentOutOfRangeException">The field number is outside 1..2^29-1.</exception>
    /// <exception cref="DllNotFoundException">libgrpcasm.so cannot be loaded (not Linux x64).</exception>
    /// <remarks>
    /// Protobuf's rules as the engine applies them: unknown fields of wire types 0, 1, 2 and 5
    /// are skipped; a repeated field replaces the earlier one (the last occurrence wins); groups,
    /// undefined wire types, field number 0, and any varint or length that runs past the end
    /// make the message malformed. The field with another wire type counts as an unknown field.
    /// </remarks>
    public static bool TryGetBytes(ReadOnlySpan<byte> message, int field, out ReadOnlySpan<byte> value) =>
        TryGetBytes(message, field, out value, out _);

    /// <summary>
    /// Finds a length-delimited field and says whether it was present: for an embedded message
    /// or a proto3 <c>optional</c> field, where absent and empty differ.
    /// </summary>
    /// <param name="message">The message.</param>
    /// <param name="field">The field number, 1..<see cref="MaxFieldNumber"/>.</param>
    /// <param name="value">The field's bytes (a slice of the message), or empty.</param>
    /// <param name="present">True when the field occurs in the message (empty or not).</param>
    /// <returns>True when the message is well-formed; false when it is malformed.</returns>
    /// <exception cref="ArgumentOutOfRangeException">The field number is outside 1..2^29-1.</exception>
    /// <exception cref="DllNotFoundException">libgrpcasm.so cannot be loaded (not Linux x64).</exception>
    /// <remarks>
    /// The native result points into the pinned message; it is turned into an offset while the
    /// message is still pinned, and the slice is taken from the span afterwards, so no pointer
    /// outlives the <c>fixed</c> block.
    /// </remarks>
    public static bool TryGetBytes(ReadOnlySpan<byte> message, int field, out ReadOnlySpan<byte> value, out bool present)
    {
        // The C function rejects field 0 itself but trusts the upper bound (a larger number
        // would never match a tag, silently): checked here, where the caller can be told.
        ArgumentOutOfRangeException.ThrowIfLessThan(field, 1);
        ArgumentOutOfRangeException.ThrowIfGreaterThan(field, MaxFieldNumber);
        byte* found;
        nuint length;
        int rc;
        long offset;
        fixed (byte* p = message)
        {
            // An empty span pins as null; the C function accepts that when the length is 0.
            rc = Native.PbBytes(p, (nuint)message.Length, (uint)field, &found, &length);
            offset = rc == 1 ? found - p : 0;
        }

        switch (rc)
        {
            case 1:
                // The decoder checked offset + length against the message's length.
                value = message.Slice((int)offset, (int)length);
                present = true;
                return true;
            case 0:
                value = default;
                present = false;
                return true;
            default:
                value = default; // -EINVAL: the out pointers are valid, so the message is malformed
                present = false;
                return false;
        }
    }
}
