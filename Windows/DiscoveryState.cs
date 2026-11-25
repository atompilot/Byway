namespace Byway;

internal sealed record DiscoveryState(bool Enabled, string Status, string? MdnsUrl = null, string? IpUrl = null)
{
    internal string? PreferredUrl => MdnsUrl ?? IpUrl;
    internal static string Label(Guid id) => "byway-" + id.ToString("N")[..12];
}

internal sealed record DiscoveryInput(bool? Enabled);
