using System.Globalization;
using System.Net;
using YamlDotNet.RepresentationModel;
using static Byway.ClashYaml;

namespace Byway;

internal sealed record ClashChoice(string Name, string[] Members, string Selected);

internal sealed class ClashConfiguration : IRoutingConfiguration
{
    private const string Direct = "DIRECT";
    private readonly List<Dictionary<string, object>> nodes = [];
    private readonly List<ClashChoice> groups = [];
    private readonly List<ClashRule> rules = [];
    private readonly List<string> warnings = [];
    private readonly ClashDns dns;
    private string final = Direct;
    private int ruleCount;

    internal IReadOnlyList<ClashChoice> Groups => groups;
    internal string[] GlobalTargets => [.. groups.Select(group => group.Name), .. nodes.Select(node => (string)node["tag"]), Direct];

    private ClashConfiguration(ClashDns dns) => this.dns = dns;

    internal static ClashConfiguration Parse(string text, IReadOnlyDictionary<string, string>? selections = null)
    {
        var root = Read(text);
        root.CheckFields("顶层", "proxies", "proxy-groups", "rules", "Proxy", "Proxy Group", "Rules",
            "dns", "hosts", "ipv6", "proxy-providers", "rule-providers", "mode", "port", "socks-port",
            "mixed-port", "allow-lan", "bind-address", "external-controller", "secret", "log-level",
            "unified-delay", "tcp-concurrent");
        if (!root.Text("mode", "rule").Equals("rule", StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Clash 配置请先切到规则模式，再导入 Byway。");
        foreach (string provider in new[] { "proxy-providers", "rule-providers" })
        {
            if (root.Get(provider) is { } data && Mapping(data, provider).Children.Count > 0)
                throw new InvalidDataException($"此 Clash 配置使用 {provider}，当前无法保留其更新行为。");
        }
        var result = new ClashConfiguration(ClashDns.Parse(root));
        result.warnings.Add("原配置的代理规则统一使用 Byway 当前节点。导入时选中的直连和拒绝策略继续生效。");
        if (new[] { ("proxies", "Proxy"), ("proxy-groups", "Proxy Group"), ("rules", "Rules") }
            .Any(pair => root.Get(pair.Item1) is not null && root.Get(pair.Item2) is not null))
            result.warnings.Add("同时存在新旧字段时，使用小写 proxies、proxy-groups、rules。");
        if (new[] { "port", "socks-port", "mixed-port", "allow-lan", "bind-address", "external-controller", "secret" }
            .Any(key => root.Get(key) is not null))
            result.warnings.Add("监听端口、局域网代理和控制接口使用 Byway 的设置。");

        var known = new HashSet<string>(StringComparer.Ordinal) { Direct, "REJECT" };
        foreach (var value in Sequence(root.Get("proxies") ?? root.Get("Proxy"), "proxies"))
        {
            var node = Mapping(value, "节点");
            string name = node.Text("name");
            AddName(known, name);
            if (result.nodes.Count == 1024)
                throw new InvalidDataException("每份 Clash 配置最多支持 1024 个节点。");
            result.nodes.Add(ParseNode(node));
        }
        foreach (var value in Sequence(root.Get("proxy-groups") ?? root.Get("Proxy Group"), "proxy-groups"))
        {
            var group = Mapping(value, "策略组");
            string name = group.Text("name");
            AddName(known, name);
            if (result.groups.Count == 128)
                throw new InvalidDataException("每份 Clash 配置最多支持 128 个策略组。");
            if (group.Text("type") != "select")
                throw new InvalidDataException($"策略组「{name}」当前仅支持 select 手选策略。");
            group.CheckFields("策略组", "name", "type", "proxies");
            string[] members = Texts(group.Get("proxies"), "策略组成员");
            if (members.Length == 0 || members.Distinct(StringComparer.Ordinal).Count() != members.Length)
                throw new InvalidDataException($"策略组「{name}」必须有成员且成员不能重复。");
            string selected = selections is not null && selections.TryGetValue(name, out var previous) && members.Contains(previous)
                ? previous : members[0];
            result.groups.Add(new(name, members, selected));
        }
        result.ValidateGroups(known);

        string[] lines = Texts(root.Get("rules") ?? root.Get("Rules"), "rules");
        if (lines.Length is 0 or > 30_000)
            throw new InvalidDataException("Clash 配置必须包含 1 至 30000 条规则。");
        result.ruleCount = lines.Length;
        for (int i = 0; i < lines.Length; i++)
        {
            string[] parts = lines[i].Split(',', StringSplitOptions.TrimEntries);
            if (parts is ["MATCH" or "FINAL", var target] && i == lines.Length - 1)
            {
                CheckTarget(target, known, i + 1);
                result.final = target;
            }
            else
                result.rules.Add(ParseRule(parts, known, i + 1));
        }
        return result;
    }

    public RoutingReport Report() => new(ruleCount, 0, RouteTarget(final, "PROXY"), dns.Summary,
        [.. warnings], nodes.Count, groups.Count);

    internal string Compile(Node? node, int port, int probePort, int dnsPort, int lookupPort,
        string geoIpPath, string? trafficAddress, string? trafficToken, RoutingMode mode, CaptureMode capture)
    {
        var outbounds = new List<object> { new { type = "direct", tag = Direct } };
        string proxy = mode == RoutingMode.Direct ? Direct : node!.Id.ToString();
        if (mode != RoutingMode.Direct)
            outbounds.Add(node!.Outbound);
        string destination = mode switch
        {
            RoutingMode.Direct => Direct,
            RoutingMode.Global => proxy,
            _ => RouteTarget(final, proxy)
        };
        List<object> inbounds = [ProxyCoreConfiguration.Mixed("byway", port), ProxyCoreConfiguration.Mixed("byway-probe", probePort)];
        var matches = new List<object> { new { inbound = new[] { "byway-probe" }, action = "route", outbound = proxy } };
        if (dns.NeedsBootstrapListener)
            AddDnsListener(ClashDns.BootstrapInbound, dnsPort);
        if (dns.NeedsLookupListener)
            AddDnsListener(ClashDns.LookupInbound, lookupPort);
        var route = new Dictionary<string, object>
        {
            ["final"] = IsReject(destination) ? Direct : destination,
            ["default_domain_resolver"] = dns.NeedsLookupListener ? ClashDns.LookupResolver : "system",
            ["rules"] = matches
        };
        ProxyCoreConfiguration.ConfigureCapture(capture, inbounds, route, matches, Direct);
        bool resolved = false;
        if (mode == RoutingMode.Rule)
        {
            foreach (var rule in rules)
            {
                if (rule.Resolve && !resolved)
                {
                    matches.Add(new { action = "resolve" });
                    resolved = true;
                }
                var match = new Dictionary<string, object>(rule.Match);
                ApplyAction(match, RouteTarget(rule.Target, proxy));
                matches.Add(match);
            }
        }
        if (IsReject(destination))
        {
            var reject = new Dictionary<string, object>();
            ApplyAction(reject, destination);
            matches.Add(reject);
        }
        if (mode == RoutingMode.Rule && rules.Any(rule => rule.Match.ContainsKey("rule_set")))
        {
            if (!File.Exists(geoIpPath))
                throw new InvalidDataException("缺少 GEOIP,CN 数据，请重新安装 Byway。");
            route["rule_set"] = new[] { new { type = "local", tag = "geoip-cn", format = "binary", path = geoIpPath } };
        }
        return ProxyCoreConfiguration.Serialize(dns.Compile(dnsPort, lookupPort, capture), inbounds, outbounds, route, trafficAddress, trafficToken);

        void AddDnsListener(string tag, int listenPort)
        {
            inbounds.Add(new { type = "direct", tag, network = "udp", listen = "127.0.0.1", listen_port = listenPort });
            matches.Add(new { inbound = new[] { tag }, action = "hijack-dns" });
        }
    }

    private string RouteTarget(string name, string proxy)
    {
        while (groups.Find(item => item.Name == name) is { } group)
            name = group.Selected;
        return name == Direct || IsReject(name) ? name : proxy;
    }

    private static void AddName(HashSet<string> known, string name)
    {
        if (name.Length > 256 || name.Any(char.IsControl) || IsReject(name) || !known.Add(name))
            throw new InvalidDataException("Clash 节点或策略组名称重复、保留或超出长度范围。");
    }

    private static void CheckTarget(string target, HashSet<string> known, int number)
    {
        if (!known.Contains(target) && !IsReject(target))
            throw new InvalidDataException($"Clash 第 {number} 条规则引用了不存在或暂不支持的出口。");
    }

    private static bool IsReject(string name) => name is "REJECT" or "REJECT-DROP";

    private static void ApplyAction(Dictionary<string, object> match, string target)
    {
        if (IsReject(target))
        {
            match["action"] = "reject";
            if (target == "REJECT-DROP")
                match["method"] = "drop";
        }
        else
        {
            match["action"] = "route";
            match["outbound"] = target;
        }
    }

    private void ValidateGroups(HashSet<string> known)
    {
        var byName = groups.ToDictionary(group => group.Name, StringComparer.Ordinal);
        var checkedNames = new HashSet<string>(StringComparer.Ordinal);
        var path = new HashSet<string>(StringComparer.Ordinal);
        foreach (var group in groups)
            Visit(group);

        void Visit(ClashChoice group)
        {
            if (checkedNames.Contains(group.Name))
                return;
            if (!path.Add(group.Name))
                throw new InvalidDataException($"策略组「{group.Name}」循环引用。");
            foreach (string member in group.Members)
            {
                if (!known.Contains(member))
                    throw new InvalidDataException($"策略组「{group.Name}」包含不存在或暂不支持的成员。");
                if (byName.TryGetValue(member, out var nested))
                    Visit(nested);
            }
            path.Remove(group.Name);
            checkedNames.Add(group.Name);
        }
    }

    private static ClashRule ParseRule(string[] parts, HashSet<string> known, int number)
    {
        if (parts.Length is < 3 or > 4 || parts[1].Length == 0)
            throw new InvalidDataException($"Clash 第 {number} 条规则无法转换。");
        string type = parts[0], value = parts[1], target = parts[2];
        CheckTarget(target, known, number);
        bool ip = type is "IP-CIDR" or "IP-CIDR6" or "GEOIP";
        if (parts.Length == 4 && (!ip || parts[3] != "no-resolve"))
            throw new InvalidDataException($"Clash 第 {number} 条规则含有暂不支持的选项。");
        var match = new Dictionary<string, object>();
        switch (type)
        {
            case "DOMAIN": match["domain"] = new[] { value.ToLowerInvariant() }; break;
            case "DOMAIN-SUFFIX": match["domain_suffix"] = new[] { value.ToLowerInvariant() }; break;
            case "DOMAIN-KEYWORD": match["domain_keyword"] = new[] { value.ToLowerInvariant() }; break;
            case "IP-CIDR":
            case "IP-CIDR6":
                if (!IPNetwork.TryParse(value, out _))
                    throw new InvalidDataException($"Clash 第 {number} 条规则包含无效 CIDR。");
                match["ip_cidr"] = new[] { value };
                break;
            case "DST-PORT":
                var ports = value.Split('-', StringSplitOptions.TrimEntries);
                int first = Port(ports[0], $"第 {number} 条规则");
                if (ports.Length == 1)
                    match["port"] = new[] { first };
                else if (ports.Length == 2 && Port(ports[1], $"第 {number} 条规则") >= first)
                    match["port_range"] = new[] { $"{ports[0]}:{ports[1]}" };
                else
                    throw new InvalidDataException($"Clash 第 {number} 条规则包含无效端口范围。");
                break;
            case "GEOIP" when value.Equals("CN", StringComparison.OrdinalIgnoreCase):
                match["rule_set"] = new[] { "geoip-cn" };
                break;
            default: throw new InvalidDataException($"Clash 第 {number} 条规则的类型 {type} 暂不支持。");
        }
        return new(match, target, ip && parts.Length == 3);
    }

    internal static int Port(string value, string label) =>
        int.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out int port) && port is > 0 and <= 65535
            ? port : throw new InvalidDataException($"Clash 配置中的 {label} 端口无效。");

    private static Dictionary<string, object> ParseNode(YamlMappingNode node)
    {
        string type = node.Text("type"), host = node.Text("server").Trim('[', ']');
        if (Uri.CheckHostName(host) == UriHostNameType.Unknown)
            throw new InvalidDataException("Clash 节点的服务器地址无效。");
        var outbound = new Dictionary<string, object>
        {
            ["type"] = type == "ss" ? "shadowsocks" : type, ["tag"] = node.Text("name"),
            ["server"] = host, ["server_port"] = Port(node.Text("port"), "节点")
        };
        if (!node.Flag("udp"))
            outbound["network"] = "tcp";
        switch (type)
        {
            case "ss":
                node.CheckFields("Shadowsocks 节点", "name", "type", "server", "port", "cipher", "password", "udp");
                outbound["method"] = node.Text("cipher");
                outbound["password"] = node.Text("password");
                break;
            case "vmess":
                node.CheckFields("VMess 节点", "name", "type", "server", "port", "uuid", "alterId", "cipher", "udp",
                    "tls", "skip-cert-verify", "servername", "network", "ws-opts");
                if (!Guid.TryParse(node.Text("uuid"), out var uuid) ||
                    !byte.TryParse(node.Text("alterId", "0"), NumberStyles.None, CultureInfo.InvariantCulture, out byte alterId))
                    throw new InvalidDataException("Clash VMess 节点的 UUID 或 alterId 无效。");
                outbound["uuid"] = uuid.ToString();
                outbound["alter_id"] = (int)alterId;
                outbound["security"] = node.Text("cipher", "auto");
                if (node.Flag("tls"))
                    outbound["tls"] = new { enabled = true, server_name = node.Text("servername", host),
                        insecure = node.Flag("skip-cert-verify") };
                string network = node.Text("network", "tcp");
                if (network == "ws")
                {
                    var ws = Mapping(node.Get("ws-opts"), "ws-opts");
                    ws.CheckFields("ws-opts", "headers", "path");
                    var headers = ws.Get("headers") is { } values ? Mapping(values, "WebSocket headers").Children
                        .ToDictionary(pair => Scalar(pair.Key, "header"), pair => Scalar(pair.Value, "header")) : null;
                    outbound["transport"] = new { type = "ws", path = ws.Text("path", "/"), headers };
                }
                else if (network != "tcp" || node.Get("ws-opts") is not null)
                    throw new InvalidDataException("Clash VMess 节点当前仅支持 TCP 和 WebSocket。");
                break;
            default: throw new InvalidDataException($"Clash 节点协议 {type} 暂不支持。");
        }
        return outbound;
    }

    private sealed record ClashRule(Dictionary<string, object> Match, string Target, bool Resolve);
}
