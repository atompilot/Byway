using System.Text.Json;
using System.Text.Json.Serialization;

namespace Byway;

internal static class ProxyCoreConfiguration
{
    internal const string TunTag = "byway-tun";
    internal const string TunInterface = "Byway-TUN";
    private static readonly JsonSerializerOptions Json = new() { DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull };

    internal static string Create(Node? node, int port, int probePort, IRoutingConfiguration? routing,
        string geoIpPath, string? trafficAddress = null, string? trafficToken = null, int dnsPort = 3, int lookupPort = 4,
        RoutingMode mode = RoutingMode.Rule, CaptureMode capture = CaptureMode.SystemProxy,
        Dictionary<int, RoutingRuleMatch>? ruleTest = null)
    {
        if (node is null && mode != RoutingMode.Direct)
            throw new InvalidOperationException("请先选择节点。");
        if (routing is ClashConfiguration clash)
            return clash.Compile(node, port, probePort, dnsPort, lookupPort, geoIpPath, trafficAddress, trafficToken, mode, capture);
        var imported = routing as ShadowrocketConfiguration;
        string proxy = mode == RoutingMode.Direct ? "direct" : node!.Id.ToString();
        List<object> inbounds = [Mixed("byway", port)];
        List<object> outbounds = mode == RoutingMode.Direct ? [] : [node!.Outbound];
        var route = new Dictionary<string, object> { ["final"] = proxy, ["default_domain_resolver"] = "system" };
        var dns = new Dictionary<string, object>();
        List<object> servers = [SystemDns(capture)];
        var rules = new List<object>();
        ConfigureCapture(capture, inbounds, route, rules, excludedRoutes: imported?.TunExcludedRoutes);
        if (imported is not null)
        {
            if (ruleTest is null)
            {
                inbounds.Add(Mixed("byway-probe", probePort));
                rules.Add(new { inbound = new[] { "byway-probe" }, action = "route", outbound = proxy });
            }
            if (imported.IPv6Restriction is { } ipv6)
            {
                ruleTest?.Add(rules.Count, ipv6);
                rules.Add(new { ip_version = 6, action = "reject" });
            }

            string primary = AddDns(imported, dns, servers, rules);
            outbounds.Add(new { type = "direct", tag = "direct", domain_resolver = primary });
            if (mode == RoutingMode.Rule)
            {
                foreach (var rule in imported.Bypass)
                    AddRule(rule);
                bool resolved = false;
                foreach (ImportRule rule in imported.Rules)
                {
                    if (rule.Resolve && !resolved)
                    {
                        rules.Add(new { action = "resolve" });
                        resolved = true;
                    }
                    AddRule(rule);
                }
                if (ruleTest is not null)
                {
                    ruleTest.Add(rules.Count, imported.FinalSource);
                    rules.Add(new { action = "reject" });
                }
                else if (imported.Final == RoutePolicy.Reject)
                    rules.Add(new { action = "reject" });
                else if (imported.Final == RoutePolicy.Proxy && (resolved || imported.Hosts.Count > 0))
                    rules.Add(new { action = "route", outbound = proxy, preserve_domain = true });
                route["final"] = imported.Final == RoutePolicy.Direct ? "direct" : proxy;
                if (imported.UsesGeoIp)
                {
                    if (!File.Exists(geoIpPath))
                        throw new InvalidDataException("缺少 GEOIP,CN 数据，请重新安装 Byway。");
                    route["rule_set"] = new[] { new { type = "local", tag = "geoip-cn", format = "binary", path = geoIpPath } };
                }
            }
        }
        else if (mode == RoutingMode.Direct)
        {
            outbounds.Add(new { type = "direct", tag = "direct" });
        }
        else if (capture == CaptureMode.Tun)
        {
            outbounds.Add(new { type = "direct", tag = "direct" });
        }
        else if (ruleTest is not null)
        {
            ruleTest.Add(rules.Count, new("FINAL", "PROXY", "FINAL,PROXY", null));
            rules.Add(new { action = "reject" });
        }
        if (rules.Count > 0)
            route["rules"] = rules;
        dns["servers"] = servers;

        return Serialize(dns, inbounds, outbounds, route, trafficAddress, trafficToken, ruleTest is null ? "warn" : "debug");

        void AddRule(ImportRule rule)
        {
            if (ruleTest is null)
            {
                rules.Add(rule.ToEngineRule(proxy));
                return;
            }
            ruleTest.Add(rules.Count, rule.Source!);
            rules.Add(new Dictionary<string, object> { [rule.Field] = new[] { rule.Value }, ["action"] = "reject" });
        }
    }

    internal static string Serialize(object dns, List<object> inbounds, List<object> outbounds, object route,
        string? trafficAddress, string? trafficToken, string level = "warn") =>
        JsonSerializer.Serialize(new
        {
            log = new { level }, dns, inbounds, outbounds, route,
            experimental = trafficAddress is null ? null : new
            {
                clash_api = new { external_controller = trafficAddress, secret = trafficToken }
            }
        }, Json);

    private static string AddDns(ShadowrocketConfiguration imported, Dictionary<string, object> dns,
        List<object> servers, List<object> routeRules)
    {
        const string configured = "byway-dns";
        string primary = "system";
        if (imported.Dns != "system")
        {
            primary = configured;
            if (Uri.TryCreate(imported.Dns, UriKind.Absolute, out var url) && url.Scheme == "https")
                servers.Add(new { type = "https", tag = configured, server = url.IdnHost.Trim('[', ']'), server_port = url.Port,
                    path = url.AbsolutePath == "/" ? "/dns-query" : url.AbsolutePath, domain_resolver = "system" });
            else
                servers.Add(new { type = "udp", tag = configured, server = imported.Dns });
        }
        dns["final"] = primary;
        if (imported.Strategy is { } strategy)
            dns["strategy"] = strategy;
        if (imported.Hosts.Count > 0)
        {
            string[] domains = imported.Hosts.Keys.ToArray();
            servers.Add(new { type = "hosts", tag = "byway-hosts", predefined = imported.Hosts });
            dns["rules"] = new[] { new { domain = domains, action = "route", server = "byway-hosts" } };
            routeRules.Add(new { domain = domains, action = "resolve" });
        }
        return primary;
    }

    internal static object Mixed(string tag, int port) => new { type = "mixed", tag, listen = "127.0.0.1", listen_port = port };

    internal static object SystemDns(CaptureMode capture) => new { type = "local", tag = "system", prefer_go = capture == CaptureMode.Tun };

    internal static void ConfigureCapture(CaptureMode capture, List<object> inbounds, Dictionary<string, object> route,
        List<object> rules, string directTag = "direct", IReadOnlyCollection<string>? excludedRoutes = null)
    {
        if (capture != CaptureMode.Tun)
            return;

        inbounds.Add(new
        {
            type = "tun", tag = TunTag, interface_name = TunInterface,
            address = new[] { "198.18.0.1/30", "fdfe:dcba:9876::1/126" },
            mtu = 1400, auto_route = true, strict_route = true, dns_mode = "native",
            route_exclude_address = new[]
            {
                "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12",
                "192.168.0.0/16", "224.0.0.0/4", "255.255.255.255/32", "::1/128", "fc00::/7", "fe80::/10", "ff00::/8"
            }.Union(excludedRoutes ?? []).ToArray()
        });
        route["auto_detect_interface"] = true;
        // Tailscale owns the encrypted underlay of its excluded private routes.
        rules.Add(new { inbound = new[] { TunTag }, process_name = new[] { "tailscaled.exe", "tailscale-ipn.exe" },
            action = "route", outbound = directTag });
        rules.Add(new { inbound = new[] { TunTag }, port = new[] { 53 }, action = "hijack-dns" });
        rules.Add(new { inbound = new[] { TunTag }, action = "sniff" });
    }
}
