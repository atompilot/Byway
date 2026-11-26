using System.Globalization;
using System.Net;

namespace Byway;

internal sealed record ProbeResult(long? Milliseconds, string? ExitIp, string? Error, string? ExitRegionCode = null)
{
    internal bool Succeeded => Error is null;
    internal DateTimeOffset CompletedAtUtc { get; init; } = DateTimeOffset.UtcNow;

    internal string? ExitRegionName
    {
        get
        {
            if (ExitRegionCode is null)
                return null;
            try { return new RegionInfo(ExitRegionCode).DisplayName; }
            catch (ArgumentException) { return null; }
        }
    }

    internal static ProbeResult FromResponse(string text, bool cloudflareTrace, long milliseconds)
    {
        string[] lines = cloudflareTrace ? text.Split('\n') : [];
        string? ip = cloudflareTrace ? TraceValue("ip=") : text.Trim();
        if (!IPAddress.TryParse(ip, out _))
            return new(null, null, L10n.Text("HTTPS 响应缺少出口 IP"));

        string? code = TraceValue("loc=");
        if (code is not { Length: 2 } || code is "XX" or "ZZ" || !code.All(char.IsAsciiLetterUpper))
            code = null;
        return new(milliseconds, ip, null, code);

        string? TraceValue(string key) =>
            lines.FirstOrDefault(line => line.StartsWith(key, StringComparison.Ordinal))?[key.Length..].Trim();
    }
}
