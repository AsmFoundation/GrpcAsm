// =============================================================================================
// analyze.cs: the paired verdict of run.sh's blocks. A .NET 10 file-based app; it replaced
// analyze.py on 2026-11-18 and prints exactly what analyze.py printed (checked against the
// three committed results folders).
//
// Usage: dotnet run analyze.cs -- RESULTS_DIR
//
// Reads RESULTS_DIR/raw.jsonl (one kvbench JSON line per run, labels "<protocol>-b<block>")
// and prints, as Markdown:
//   - one row per block: each client's throughput, client CPU per request, server CPU per
//     request and p50/p99 latency, and the block's ratios (grpcasm / grpc);
//   - the summary: the median ratio, its range over the blocks, how many blocks favor GrpcAsm's
//     client, and the two-sided sign-test p-value of that count.
//
// Why ratios per block: run.sh runs both clients back to back in each block, in alternating
// order. A host whose speed drifts (other programs on the same PC) moves both runs of a block
// together, so the ratio inside a block is what is compared, never two absolute numbers from
// different moments.
//
// Every run must be valid (kvbench's own verdict: no errors, no misses, no bad values);
// otherwise the program stops, naming the run.
// =============================================================================================
using System.Globalization;
using System.Numerics;
using System.Text;
using System.Text.Json;

return Analyze.Run(args);

/// <summary>The analysis; see the file header.</summary>
internal static class Analyze
{
    /// <summary>Reads the runs, prints the per-block table and the summary.</summary>
    /// <param name="args">One argument: the results folder.</param>
    /// <returns>0, 1 for an invalid run, 2 for a usage error.</returns>
    public static int Run(string[] args)
    {
        // The table holds µ, × and ÷: UTF-8 whatever the console's code page.
        Console.OutputEncoding = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false);
        if (args.Length != 1)
        {
            Console.WriteLine("usage: dotnet run analyze.cs -- RESULTS_DIR (see the file header)");
            return 2;
        }

        // Keyed by (block, protocol); a later line for the same run replaces an earlier one.
        var runs = new Dictionary<(int Block, string Protocol), JsonElement>();
        foreach (string line in File.ReadAllLines(Path.Combine(args[0], "raw.jsonl")))
        {
            if (string.IsNullOrWhiteSpace(line))
            {
                continue;
            }

            JsonElement run = JsonDocument.Parse(line).RootElement;
            JsonElement result = run.TryGetProperty("result", out JsonElement r) ? r : default;
            string label = run.GetProperty("label").GetString()!;
            if (result.ValueKind != JsonValueKind.Object || !result.TryGetProperty("valid", out JsonElement valid) || valid.ValueKind != JsonValueKind.True)
            {
                string error = result.ValueKind == JsonValueKind.Object && result.TryGetProperty("error_text", out JsonElement e) ? e.ToString() : "None";
                Console.Error.WriteLine($"invalid run {label}: {error}");
                return 1;
            }

            int split = label.LastIndexOf("-b", StringComparison.Ordinal);
            runs[(int.Parse(label[(split + 2)..], CultureInfo.InvariantCulture), label[..split])] = result;
        }

        string[] keys = ["ops", "client", "server", "p50", "p99"];
        var ratios = keys.ToDictionary(k => k, _ => new List<double>());
        var rows = new List<string>();
        foreach (int block in runs.Keys.Select(k => k.Block).Distinct().Order())
        {
            if (!runs.TryGetValue((block, "grpc"), out JsonElement g) || !runs.TryGetValue((block, "grpcasm"), out JsonElement a))
            {
                continue;
            }

            double ops = Number(a, "ops_per_sec") / Number(g, "ops_per_sec");
            double client = PerOpNs(a, "client_cpu_s") / PerOpNs(g, "client_cpu_s");
            double server = PerOpNs(a, "server_cpu_s") / PerOpNs(g, "server_cpu_s");
            double p50 = Latency(a, "p50") / Latency(g, "p50");
            double p99 = Latency(a, "p99") / Latency(g, "p99");
            double[] values = [ops, client, server, p50, p99];
            for (int i = 0; i < keys.Length; i++)
            {
                ratios[keys[i]].Add(values[i]);
            }

            rows.Add(
                $"| {block} | {Fixed(Number(g, "ops_per_sec") / 1e6, 2)}M | {Fixed(Number(a, "ops_per_sec") / 1e6, 2)}M | **{Fixed(ops, 2)}×** " +
                $"| {Fixed(PerOpNs(g, "client_cpu_s"), 0)} | {Fixed(PerOpNs(a, "client_cpu_s"), 0)} " +
                $"| {Fixed(PerOpNs(g, "server_cpu_s"), 0)} | {Fixed(PerOpNs(a, "server_cpu_s"), 0)} " +
                $"| {Fixed(Latency(g, "p50"), 0)} / {Fixed(Latency(g, "p99"), 0)} " +
                $"| {Fixed(Latency(a, "p50"), 0)} / {Fixed(Latency(a, "p99"), 0)} |");
        }

        Console.WriteLine("| block | nghttp2 ops/s | GrpcAsm ops/s | ratio | nghttp2 client ns/req " +
                          "| GrpcAsm client ns/req | server ns/req (nghttp2) | server ns/req (GrpcAsm) " +
                          "| nghttp2 p50/p99 µs | GrpcAsm p50/p99 µs |");
        Console.WriteLine("|---|---|---|---|---|---|---|---|---|---|");
        // Environment.NewLine between rows too: Python's print translates every "\n" of its
        // text into the platform's line end, so both write the same bytes on each OS.
        Console.WriteLine(string.Join(Environment.NewLine, rows));
        Console.WriteLine();
        int n = ratios["ops"].Count;
        (string Key, string Label, Func<double, bool> Better)[] labels =
        [
            ("ops", "throughput (GrpcAsm ÷ nghttp2)", r => r > 1),
            ("client", "client CPU per request (GrpcAsm ÷ nghttp2)", r => r < 1),
            ("server", "server CPU per request (with GrpcAsm ÷ with nghttp2)", r => r < 1),
            ("p50", "p50 latency (GrpcAsm ÷ nghttp2)", r => r < 1),
            ("p99", "p99 latency (GrpcAsm ÷ nghttp2)", r => r < 1),
        ];
        foreach ((string key, string label, Func<double, bool> better) in labels)
        {
            List<double> values = ratios[key];
            int wins = values.Count(better);
            Console.WriteLine($"- **{label}:** median {Fixed(Median(values), 3)}, range " +
                              $"{Fixed(values.Min(), 3)}–{Fixed(values.Max(), 3)}; GrpcAsm better in {wins}/{n} blocks " +
                              $"(sign test p = {Fixed(SignTest(wins, n), 3)})");
        }

        return 0;
    }

    /// <summary>A JSON number of a kvbench result.</summary>
    /// <param name="result">kvbench's "result" object.</param>
    /// <param name="key">The property.</param>
    /// <returns>Its value.</returns>
    /// <exception cref="KeyNotFoundException">The property is missing (a malformed line).</exception>
    private static double Number(JsonElement result, string key) => result.GetProperty(key).GetDouble();

    /// <summary>A latency percentile of a kvbench result, in µs.</summary>
    /// <param name="result">kvbench's "result" object.</param>
    /// <param name="percentile">"p50" or "p99".</param>
    /// <returns>The latency.</returns>
    private static double Latency(JsonElement result, string percentile) =>
        result.GetProperty("latency_us").GetProperty(percentile).GetDouble();

    /// <summary>CPU nanoseconds per request of one side.</summary>
    /// <param name="result">kvbench's "result" object.</param>
    /// <param name="key">"client_cpu_s" or "server_cpu_s".</param>
    /// <returns>Nanoseconds per completed request, or NaN when kvbench could not read that side (a negative or null value, or no requests).</returns>
    private static double PerOpNs(JsonElement result, string key)
    {
        double seconds = result.TryGetProperty(key, out JsonElement value) && value.ValueKind == JsonValueKind.Number ? value.GetDouble() : -1;
        double ops = result.TryGetProperty("ops", out JsonElement o) && o.ValueKind == JsonValueKind.Number ? o.GetDouble() : 0;
        return seconds < 0 || ops == 0 ? double.NaN : seconds / ops * 1e9;
    }

    /// <summary>The median, as Python's statistics.median: the middle value, or the mean of the two middle ones.</summary>
    /// <param name="values">The values (at least one).</param>
    /// <returns>The median.</returns>
    private static double Median(List<double> values)
    {
        double[] sorted = values.Order().ToArray();
        int mid = sorted.Length / 2;
        return sorted.Length % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
    }

    /// <summary>Two-sided exact sign test.</summary>
    /// <param name="wins">Blocks where the ratio favors one side.</param>
    /// <param name="n">Blocks.</param>
    /// <returns>The probability of a split at least this lopsided if neither side were better.</returns>
    private static double SignTest(int wins, int n)
    {
        int k = Math.Max(wins, n - wins);
        BigInteger tail = BigInteger.Zero;
        for (int i = k; i <= n; i++)
        {
            tail += Choose(n, i);
        }

        return Math.Min(1.0, 2 * ((double)tail / Math.Pow(2, n)));
    }

    /// <summary>The binomial coefficient, exactly.</summary>
    /// <param name="n">The set size.</param>
    /// <param name="k">The subset size.</param>
    /// <returns>n choose k.</returns>
    private static BigInteger Choose(int n, int k)
    {
        BigInteger result = BigInteger.One;
        for (int i = 1; i <= k; i++)
        {
            result = result * (n - k + i) / i;
        }

        return result;
    }

    /// <summary>
    /// Formats a number as Python's format(value, ".&lt;digits&gt;f"): the exact binary value,
    /// rounded half to even.
    /// </summary>
    /// <param name="value">The number.</param>
    /// <param name="digits">Digits after the point.</param>
    /// <returns>The text ("nan" for NaN, as Python prints it).</returns>
    /// <remarks>
    /// Why not ToString("F2"): .NET rounds an exact decimal midpoint away from zero (186.5 gives
    /// "187"), Python to even ("186"). Latencies such as 186.50 µs are exact midpoints, so the
    /// two would print different tables. Here the double is expanded exactly, as a rational
    /// mantissa × 2^exponent, before rounding.
    /// </remarks>
    private static string Fixed(double value, int digits)
    {
        if (double.IsNaN(value))
        {
            return "nan";
        }

        if (double.IsInfinity(value))
        {
            return value > 0 ? "inf" : "-inf";
        }

        long bits = BitConverter.DoubleToInt64Bits(value);
        bool negative = bits < 0;
        int exponent = (int)((bits >> 52) & 0x7FF);
        long mantissa = bits & 0xFFFFFFFFFFFFFL;
        if (exponent == 0)
        {
            exponent = 1; // subnormal: no implicit leading 1
        }
        else
        {
            mantissa |= 1L << 52;
        }

        exponent -= 1075; // value = mantissa * 2^exponent
        BigInteger numerator = mantissa * BigInteger.Pow(10, digits);
        BigInteger denominator = BigInteger.One;
        if (exponent > 0)
        {
            numerator <<= exponent;
        }
        else
        {
            denominator <<= -exponent;
        }

        BigInteger quotient = BigInteger.DivRem(numerator, denominator, out BigInteger remainder);
        BigInteger twice = remainder * 2;
        if (twice > denominator || (twice == denominator && !quotient.IsEven))
        {
            quotient++;
        }

        string text = quotient.ToString(CultureInfo.InvariantCulture).PadLeft(digits + 1, '0');
        if (digits > 0)
        {
            text = text[..^digits] + "." + text[^digits..];
        }

        return negative ? "-" + text : text;
    }
}
