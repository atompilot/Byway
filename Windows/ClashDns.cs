using System.Net;
using YamlDotNet.RepresentationModel;
using static Byway.ClashYaml;

namespace Byway;

internal sealed class ClashDns
{
    internal const string BootstrapInbound = "clash-bootstrap-in";
    internal const string LookupInbound = "clash-lookup-in";
    internal const string LookupResolver = "clash-lookup";
    private const string BootstrapResolver = "clash-bootstrap";
    private readonly List<Resolver> upstreams = [];
    private readonly List<Resolver> bootstrap = [];
    private readonly List<(string Field, string Domain, List<Resolver> Resolvers)> policies = [];
    private readonly Dictionary<string, string[]> hosts = new(StringComparer.OrdinalIgnoreCase);
    private bool preferV4;

    internal string Summary => upstreams.Count == 0 ? "system" : L10n.Format($"{upstreams.Count} 个主 DNS · {policies.Count} 项策略");
    internal bool NeedsBootstrapListener => bootstrap.Count > 1 && AllUpstreams().Any(item => item.IsDomain);
    internal bool NeedsLookupListener => hosts.Count > 0 || upstreams.Count > 0;

    private IEnumerable<Resolver> AllUpstreams() => upstreams.Concat(policies.SelectMany(item => item.Resolvers));

    internal static ClashDns Parse(YamlMappingNode root)
    {
        var result = new ClashDns();
        var yaml = root.Get("dns") is { } dns ? Mapping(dns, "dns") : new YamlMappingNode();
        if (yaml.Flag("use-hosts", true) && root.Get("hosts") is { } data)
        {
            foreach (var pair in Mapping(data, "hosts").Children)
            {
                string domain = Scalar(pair.Key, "hosts").ToLowerInvariant();
                if (Uri.CheckHostName(domain) != UriHostNameType.Dns)
                    throw new InvalidDataException(L10n.Text("Clash hosts 当前仅支持精确域名。"));
                string[] ips = Values(pair.Value, "hosts");
                if (ips.Length == 0 || ips.Any(value => !IPAddress.TryParse(value, out _)))
                    throw new InvalidDataException(L10n.Text("Clash hosts 当前仅支持 IPv4 和 IPv6 地址。"));
                if (!result.hosts.TryAdd(domain, ips))
                    throw new InvalidDataException(L10n.Text("Clash hosts 包含重复域名。"));
            }
        }
        if (!yaml.Flag("enable"))
            return result;
        yaml.CheckFields("dns", "enable", "ipv6", "use-hosts", "default-nameserver", "nameserver",
            "nameserver-policy", "enhanced-mode", "listen");
        if (yaml.Text("enhanced-mode", "redir-host") != "redir-host")
            throw new InvalidDataException(L10n.Text("此 Clash DNS 配置使用 Fake-IP，当前仅支持 redir-host。"));
        result.preferV4 = !yaml.Flag("ipv6");
        result.bootstrap.AddRange(Texts(yaml.Get("default-nameserver"), "default-nameserver")
            .Select((value, index) => ParseResolver(value, $"bootstrap-{index + 1}", mustBeIp: true)));
        result.upstreams.AddRange(Texts(yaml.Get("nameserver"), "nameserver")
            .Select((value, index) => ParseResolver(value, $"nameserver-{index + 1}")));
        if (yaml.Get("nameserver-policy") is { } policy)
        {
            foreach (var pair in Mapping(policy, "nameserver-policy").Children)
            {
                string domain = Scalar(pair.Key, "nameserver-policy").ToLowerInvariant();
                string field = "domain";
                if (domain.StartsWith("+.") || domain.StartsWith("*.") || domain.StartsWith('.'))
                {
                    field = "domain_suffix";
                    if (domain.StartsWith("+."))
                        domain = domain[2..];
                    else if (domain.StartsWith("*."))
                        domain = domain[1..];
                }
                if (Uri.CheckHostName(domain.TrimStart('.')) != UriHostNameType.Dns)
                    throw new InvalidDataException(L10n.Text("Clash nameserver-policy 含有暂不支持的域名匹配。"));
                var resolvers = Values(pair.Value, "nameserver-policy").Select((value, index) =>
                    ParseResolver(value, $"policy-{result.policies.Count + 1}-{index + 1}")).ToList();
                if (resolvers.Count == 0)
                    throw new InvalidDataException(L10n.Text("Clash nameserver-policy 缺少上游。"));
                result.policies.Add((field, domain, resolvers));
            }
        }
        if (result.upstreams.Count == 0)
            throw new InvalidDataException(L10n.Text("Clash 启用 DNS 后需要配置 nameserver。"));
        return result;
    }

    internal object Compile(int bootstrapPort, int lookupPort, CaptureMode capture)
    {
        var servers = new List<object> { ProxyCoreConfiguration.SystemDns(capture) };
        var rules = new List<object>();
        if (hosts.Count > 0)
        {
            servers.Add(new { type = "hosts", tag = "clash-hosts", predefined = hosts });
            rules.Add(new { domain = hosts.Keys, action = "route", server = "clash-hosts" });
        }
        string bootstrapTag = bootstrap.FirstOrDefault()?.Tag ?? "system";
        // A dial resolver names one transport. Route its loopback queries through the configured upstreams.
        if (NeedsBootstrapListener)
        {
            bootstrapTag = BootstrapResolver;
            servers.Add(new { type = "udp", tag = BootstrapResolver, server = "127.0.0.1", server_port = bootstrapPort });
            AddRoutes(rules, bootstrap.Select(item => item.Tag).ToArray(), "inbound", [BootstrapInbound]);
        }
        if (NeedsLookupListener)
            servers.Add(new { type = "udp", tag = LookupResolver, server = "127.0.0.1", server_port = lookupPort });
        servers.AddRange(bootstrap.Select(item => item.ToEngine(null)));
        servers.AddRange(AllUpstreams().Select(item => item.ToEngine(item.IsDomain ? bootstrapTag : null)));
        foreach (var (field, name, resolvers) in policies.OrderBy(item => item.Field == "domain" ? 0 : 1)
                     .ThenByDescending(item => item.Domain.Length))
            AddRoutes(rules, resolvers.Select(item => item.Tag).ToArray(), field, [name]);
        if (upstreams.Count > 1)
            AddRoutes(rules, upstreams.Select(item => item.Tag).ToArray());
        return new { servers, rules, final = upstreams.FirstOrDefault()?.Tag ?? "system", strategy = preferV4 ? "ipv4_only" : "prefer_ipv4" };
    }

    private static void AddRoutes(List<object> rules, string[] tags, string? field = null, string[]? domains = null)
    {
        Dictionary<string, object> Action(string type)
        {
            var rule = new Dictionary<string, object> { ["action"] = type };
            if (field is not null)
                rule[field] = domains!;
            return rule;
        }

        if (tags.Length == 1)
        {
            var rule = Action("route");
            rule["server"] = tags[0];
            rules.Add(rule);
            return;
        }

        foreach (string tag in tags)
        {
            var evaluate = Action("evaluate");
            evaluate["server"] = tag;
            evaluate["tag"] = tag;
            rules.Add(evaluate);
        }
        foreach (string tag in tags)
        {
            foreach (string code in new[] { "NOERROR", "NXDOMAIN" })
            {
                var respond = Action("respond");
                respond["match_response"] = tag;
                respond["race"] = true;
                respond["response_rcode"] = code;
                rules.Add(respond);
            }
        }
        rules.Add(Action("reject"));
    }

    private static string[] Values(YamlNode node, string label) =>
        node is YamlSequenceNode ? Texts(node, label) : [Scalar(node, label)];

    private static Resolver ParseResolver(string input, string tag, bool mustBeIp = false)
    {
        string address = input;
        if (IPAddress.TryParse(input, out var ip))
            address = "udp://" + (ip.AddressFamily == System.Net.Sockets.AddressFamily.InterNetworkV6 ? $"[{ip}]" : ip.ToString());
        else if (!input.Contains("://"))
            address = "udp://" + input;
        if (!Uri.TryCreate(address, UriKind.Absolute, out var uri) || uri.UserInfo.Length > 0 ||
            uri.HostNameType == UriHostNameType.Unknown || uri.Fragment.Length > 0 || uri.Query.Length > 0 ||
            uri.Scheme is not ("udp" or "tcp" or "tls" or "https"))
            throw new InvalidDataException(L10n.Text("Clash DNS 当前支持 UDP、TCP、DoT 和 DoH 上游。"));
        string host = uri.IdnHost.Trim('[', ']');
        if (mustBeIp && !IPAddress.TryParse(host, out _))
            throw new InvalidDataException(L10n.Text("Clash default-nameserver 必须使用 IP 地址。"));
        int port = uri.Port > 0 ? uri.Port : uri.Scheme switch { "tls" => 853, "https" => 443, _ => 53 };
        return new(uri.Scheme, tag, host, port, uri.Scheme == "https" ? uri.AbsolutePath : null);
    }

    private sealed record Resolver(string Type, string Tag, string Host, int Port, string? Path)
    {
        internal bool IsDomain => !IPAddress.TryParse(Host, out _);
        internal object ToEngine(string? resolver) => new { type = Type, tag = Tag, server = Host, server_port = Port,
            path = Path == "/" ? "/dns-query" : Path, domain_resolver = resolver };
    }
}
