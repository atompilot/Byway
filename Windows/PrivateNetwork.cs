using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Byway;

internal sealed record PrivateNetworkInput(string Provider, string ControlURL, string[] RelayHosts,
    string DeviceName, int[]? InboundTcpPorts = null, string RelayMode = "strict")
{
    internal const string Strict = "strict";
    internal const string TailscaleDefault = "tailscaleDefault";

    private static readonly Regex Host = new(
        @"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    private static readonly Regex Name = new(@"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", RegexOptions.CultureInvariant);

    internal PrivateNetworkInput Validate(int mixedPort)
    {
        string control;
        if (Provider == "tailscale")
            control = "https://controlplane.tailscale.com";
        else if (Provider == "headscale" && Uri.TryCreate(ControlURL?.Trim(), UriKind.Absolute, out var url) &&
            url.Scheme == "https" && Host.IsMatch(url.IdnHost) && url.AbsolutePath == "/" &&
            url.UserInfo.Length == 0 && url.Query.Length == 0 && url.Fragment.Length == 0)
            control = url.GetLeftPart(UriPartial.Authority);
        else
            throw new InvalidDataException("请填写有效的 HTTPS 协调服务器地址。");

        var hosts = RelayHosts ?? [];
        switch (RelayMode)
        {
            case TailscaleDefault:
                if (Provider != "tailscale" || hosts.Length != 0)
                    throw new InvalidDataException("跟随 Tailscale 配置仅适用于 Tailscale 账号，请留空中继域名。");
                break;
            case Strict:
                hosts = hosts.Select(host => (host ?? "").Trim().TrimEnd('.').ToLowerInvariant())
                    .Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).ToArray();
                if (hosts.Length is < 1 or > 16 || hosts.Any(host => host.Length > 253 || !Host.IsMatch(host)))
                    throw new InvalidDataException("请填写 1 到 16 个有效的中继域名。");
                break;
            default:
                throw new InvalidDataException("未知的中继模式。");
        }
        string name = (DeviceName ?? "").Trim().ToLowerInvariant();
        if (name.Length != 0 && !Name.IsMatch(name))
            throw new InvalidDataException("设备名请使用英文字母、数字或短横线。");
        var ports = (InboundTcpPorts ?? []).Distinct().Order().ToArray();
        if (ports.Length > 32 || ports.Any(port => port is < 1 or > 65535 or 8766 or 8767 || port == mixedPort))
            throw new InvalidDataException("请填写有效的服务端口，Byway 自用端口不可开放。");
        return new(Provider, control, hosts, name, ports, RelayMode);
    }
}

internal sealed record PrivateNetworkSettings(Guid Identity, PrivateNetworkInput Input, bool Enabled,
    string[]? LastAddresses = null, string? LastDnsSuffix = null)
{
    internal const string Tag = "byway-private";
    internal const string DnsTag = "byway-private-dns";
    internal static string DirectoryFor(Guid id) => Program.StatePath(Path.Combine("private-network", id.ToString("D")));
}

internal sealed record PrivateNetworkRelayAudit(string[] Hosts, bool Verified);
internal sealed record PrivateNetworkRuntime(string State, string? Network, string? DnsSuffix, string[] Addresses,
    PrivateNetworkPeer[] Peers, PrivateNetworkRelayAudit? Relays, string? AuthURL);
internal sealed record PrivateNetworkPeer(string Id, string Name, string DnsName, string Os, string[] Addresses, bool Online)
{
    public string ListLabel => $"{Name}  ·  {(Online ? "在线" : "离线")}";
}
internal sealed record PrivateNetworkProbe(string Path, string Region, double LatencyMs, string ObservedAt);
internal sealed record PrivateNetworkStatus(PrivateNetworkInput? Configuration, bool Enabled, PrivateNetworkRuntime? Runtime,
    string State);

internal static class PrivateNetworkEngine
{
    internal static string Apply(string configuration, PrivateNetworkSettings settings)
    {
        var root = JsonNode.Parse(configuration)!.AsObject();
        var direct = root["outbounds"]!.AsArray().First(outbound => outbound?["type"]?.GetValue<string>() == "direct")!["tag"]!.GetValue<string>();
        var route = root["route"]!.AsObject();
        var rules = route["rules"]!.AsArray();
        var dns = root["dns"]!.AsObject();
        var dnsRules = dns["rules"]?.AsArray();
        if (dnsRules is null)
        {
            dnsRules = new JsonArray();
            dns["rules"] = dnsRules;
        }

        // TUN must see tailnet destinations before sing-box can select its embedded endpoint.
        // Other CGNAT and ULA destinations still use the physical network.
        var tun = root["inbounds"]!.AsArray().First(inbound => inbound?["tag"]?.GetValue<string>() == ProxyCoreConfiguration.TunTag)!;
        var excluded = tun["route_exclude_address"]!.AsArray();
        for (int i = excluded.Count - 1; i >= 0; i--)
            if (excluded[i]?.GetValue<string>() is "100.64.0.0/10" or "fc00::/7")
                excluded.RemoveAt(i);

        List<JsonNode> priority = [];
        if (settings.Enabled)
        {
            var endpoint = new JsonObject
            {
                ["type"] = "tailscale", ["tag"] = PrivateNetworkSettings.Tag,
                ["control_url"] = settings.Input.ControlURL,
                ["state_directory"] = PrivateNetworkSettings.DirectoryFor(settings.Identity), ["domain_resolver"] = "system"
            };
            if (settings.Input.RelayMode == PrivateNetworkInput.TailscaleDefault)
                endpoint["byway_follow_control_relays"] = true;
            else
                endpoint["byway_relays"] = Strings(settings.Input.RelayHosts);
            if (settings.Input.DeviceName.Length != 0)
                endpoint["hostname"] = settings.Input.DeviceName;
            root["endpoints"] = new JsonArray(endpoint);
            var ports = settings.Input.InboundTcpPorts ?? [];
            if (ports.Length != 0)
                priority.Add(new JsonObject
                {
                    ["inbound"] = PrivateNetworkSettings.Tag, ["network"] = "tcp",
                    ["port"] = new JsonArray(ports.Select(port => (JsonNode?)JsonValue.Create(port)).ToArray()),
                    ["ip_cidr"] = Strings(["127.0.0.1/32", "::1/128"]),
                    ["action"] = "route", ["outbound"] = direct
                });
            priority.Add(new JsonObject { ["inbound"] = PrivateNetworkSettings.Tag, ["action"] = "reject" });
            dns["servers"]!.AsArray().Add(new JsonObject
            {
                ["type"] = "tailscale", ["tag"] = PrivateNetworkSettings.DnsTag, ["endpoint"] = PrivateNetworkSettings.Tag
            });
            dnsRules.Insert(0, new JsonObject
            {
                ["preferred_by"] = PrivateNetworkSettings.DnsTag, ["action"] = "route", ["server"] = PrivateNetworkSettings.DnsTag
            });
        }

        // DNS hijacking and sniffing precede preferred_by, which also uses the recovered host name.
        var index = 0;
        while (index < rules.Count && rules[index]?["action"]?.GetValue<string>() is "route" or "hijack-dns" or "sniff")
        {
            if (rules[index]?["action"]?.GetValue<string>() == "route" &&
                rules[index]?["process_name"] is null &&
                !(rules[index]?["inbound"] is JsonArray inbound && inbound.Count == 1 &&
                  inbound[0]?.GetValue<string>() == "byway-probe"))
                break;
            index++;
        }
        if (settings.Enabled)
            priority.Add(new JsonObject
            {
                ["preferred_by"] = PrivateNetworkSettings.Tag, ["action"] = "route", ["outbound"] = PrivateNetworkSettings.Tag
            });
        if (settings.LastAddresses is { Length: > 0 })
            priority.Add(new JsonObject { ["ip_cidr"] = Strings(settings.LastAddresses), ["action"] = "reject" });
        if (settings.LastDnsSuffix is { Length: > 0 } suffix)
        {
            priority.Add(new JsonObject { ["domain_suffix"] = suffix, ["action"] = "reject" });
            dnsRules.Insert(settings.Enabled ? 1 : 0, new JsonObject { ["domain_suffix"] = suffix, ["action"] = "reject" });
        }
        priority.Add(new JsonObject
        {
            ["inbound"] = ProxyCoreConfiguration.TunTag, ["ip_cidr"] = Strings(["100.64.0.0/10", "fc00::/7"]),
            ["action"] = "route", ["outbound"] = direct
        });
        // The inbound allowlist must run before existing matchers.
        var inboundCount = settings.Enabled ? (settings.Input.InboundTcpPorts?.Length > 0 ? 2 : 1) : 0;
        for (var i = 0; i < priority.Count; i++)
            rules.Insert(i < inboundCount ? i : index + i, priority[i]);

        return root.ToJsonString();
    }

    private static JsonArray Strings(IEnumerable<string> strings) =>
        new(strings.Select(value => (JsonNode?)JsonValue.Create(value)).ToArray());
}
