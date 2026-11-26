using System.Globalization;
using System.Net;
using System.Net.Sockets;
using System.Text;

namespace Byway;

internal sealed record ImportedRouting(Guid Id, string Name, string Text, string? SubscriptionUrl = null,
    int RefreshHours = 24, DateTimeOffset? RefreshedAt = null, Dictionary<string, string>? Selections = null,
    string? GlobalTarget = null)
{
    internal bool IsClash
    {
        get
        {
            if (SubscriptionUrl is not null)
                return true;
            using var reader = new StringReader(Text);
            while (reader.ReadLine() is { } line)
            {
                var content = line.AsSpan().Trim().TrimStart('\uFEFF').Trim();
                if (!content.IsEmpty && content[0] is not ('#' or ';'))
                    return content[0] != '[';
            }
            return false;
        }
    }

    internal IRoutingConfiguration Parse() => IsClash
        ? ClashConfiguration.Parse(Text, Selections)
        : ShadowrocketConfiguration.Parse(Text);
}

internal interface IRoutingConfiguration
{
    RoutingReport Report();
}

internal sealed record RoutingReport(int RuleCount, int BypassCount, string Final, string DnsServer, string[] Warnings,
    int NodeCount = 0, int GroupCount = 0);

internal enum RoutePolicy { Direct, Proxy, Reject }

internal sealed record RoutingRuleMatch(string Type, string Policy, string Rule, int? LineNumber);

internal sealed record ImportRule(string Field, string Value, RoutePolicy Policy, bool Resolve = false)
{
    internal RoutingRuleMatch? Source { get; init; }

    internal Dictionary<string, object> ToEngineRule(string proxyTag)
    {
        var result = new Dictionary<string, object> { [Field] = new[] { Value } };
        if (Policy == RoutePolicy.Reject)
            result["action"] = "reject";
        else
        {
            result["action"] = "route";
            result["outbound"] = Policy == RoutePolicy.Direct ? "direct" : proxyTag;
            if (Policy == RoutePolicy.Proxy)
            {
                result["preserve_domain"] = true;
                if (Field == "domain")
                    result["override_address"] = Value;
            }
        }
        return result;
    }
}

internal sealed class ShadowrocketConfiguration : IRoutingConfiguration
{
    internal const int MaxBytes = 128 * 1024;
    internal List<ImportRule> Rules { get; } = [];
    internal List<ImportRule> Bypass { get; } = [];
    internal List<string> TunExcludedRoutes { get; } = [];
    internal Dictionary<string, string[]> Hosts { get; } = new(StringComparer.OrdinalIgnoreCase);
    internal IReadOnlyList<string> Warnings => warnings;
    private readonly List<string> warnings = [];
    internal RoutePolicy Final { get; private set; } = RoutePolicy.Proxy;
    internal RoutingRuleMatch FinalSource => explicitFinal ?? new("FINAL", "PROXY", "FINAL,PROXY", null);
    internal RoutingRuleMatch? IPv6Restriction { get; private set; }
    internal string Dns { get; private set; } = "system";
    internal bool IPv6 { get; private set; } = true;
    private string? preference;
    private RoutingRuleMatch? explicitFinal;
    internal string? Strategy => IPv6 ? preference : "ipv4_only";
    internal bool UsesGeoIp => Rules.Exists(rule => rule.Field == "rule_set");

    public RoutingReport Report() => new(Rules.Count, Bypass.Count, Final.ToString().ToUpperInvariant(), Dns, warnings.ToArray());

    internal static ShadowrocketConfiguration Parse(string text)
    {
        if (string.IsNullOrWhiteSpace(text) || Encoding.UTF8.GetByteCount(text) > MaxBytes)
            throw new InvalidDataException(L10n.Text("请提供不超过 128 KB 的 UTF-8 分流配置。"));

        var config = new ShadowrocketConfiguration();
        string section = "";
        string? fallback = null;
        bool hasRuleSection = false;
        bool hasFinal = false;
        bool useSystemForDirect = false;
        using var reader = new StringReader(text);
        for (int number = 1; reader.ReadLine() is { } raw; number++)
        {
            string line = raw.Trim().TrimStart('\uFEFF').Trim();
            if (line.Length == 0 || line.StartsWith('#') || line.StartsWith(';'))
                continue;
            if (line.StartsWith('[') && line.EndsWith(']'))
            {
                section = line[1..^1].Trim().ToLowerInvariant();
                hasRuleSection |= section == "rule";
                if (section is not ("general" or "rule" or "host" or "url rewrite"))
                    config.Warn(L10n.Format($"保留 [{section}]，Windows 当前不执行此段。"));
                continue;
            }

            switch (section)
            {
                case "general":
                {
                    var (key, value) = Assignment(line, number);
                    switch (key)
                    {
                        case "dns-server": config.Dns = Resolver(value, number); break;
                        case "fallback-dns-server": fallback = value; break;
                        case "ipv6":
                            config.IPv6 = Flag(value, number);
                            config.IPv6Restriction = config.IPv6 ? null : new("IPV6", "REJECT", line, number);
                            break;
                        case "prefer-ipv6": config.preference = Flag(value, number) ? "prefer_ipv6" : "prefer_ipv4"; break;
                        case "skip-proxy": config.AddBypass(value, line, number); break;
                        case "always-real-ip": break;
                        case "private-ip-answer":
                            if (!Flag(value, number))
                                config.Warn(L10n.Text("private-ip-answer=false 已保留，Windows 保留 DNS 的私有 IP。"));
                            break;
                        case "dns-direct-system": useSystemForDirect = Flag(value, number); break;
                        case "dns-direct-fallback-proxy":
                            if (Flag(value, number))
                                config.Warn(L10n.Text("dns-direct-fallback-proxy 已保留，Windows 不会在直连解析失败时自动改走代理。"));
                            break;
                        case "udp-policy-not-supported-behaviour":
                            if (!value.Equals("REJECT", StringComparison.OrdinalIgnoreCase))
                                config.Warn(L10n.Text("不支持 UDP 转发的节点将拒绝该连接。"));
                            break;
                        case "tun-excluded-routes":
                            config.TunExcludedRoutes.AddRange(value.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries)
                                .Select(route => Cidr(route, number)));
                            break;
                        case "bypass-system":
                        case "icmp-auto-reply":
                            config.Warn(L10n.Format($"{key} 已保留，Windows 当前不执行。"));
                            break;
                        case "always-reject-url-rewrite":
                            if (Flag(value, number))
                                config.Warn(L10n.Text("always-reject-url-rewrite 已保留，Windows 当前不执行网址重写。"));
                            break;
                        default: config.Warn(L10n.Format($"{key} 已保留，Windows 当前不执行。")); break;
                    }
                    break;
                }
                case "rule":
                    if (hasFinal)
                        throw Invalid(number, L10n.Text("FINAL 后仍有分流规则。"));
                    hasFinal = config.AddRule(line, number);
                    break;
                case "host":
                    config.AddHost(line, number);
                    break;
                case "url rewrite":
                    config.Warn(L10n.Text("[URL Rewrite] 已保留，Windows 当前不执行网址重写。"));
                    break;
            }
        }
        if (!hasRuleSection || config.Rules.Count == 0 && !hasFinal)
            throw new InvalidDataException(L10n.Text("请提供包含可用规则或 FINAL 的 [Rule] 段。"));
        if (fallback is not null && !fallback.Equals(config.Dns, StringComparison.OrdinalIgnoreCase))
            config.Warn(L10n.Text("备用 DNS 已保留，Windows 当前使用主 DNS。"));
        if (useSystemForDirect && config.Dns != "system")
            config.Warn(L10n.Text("dns-direct-system 已保留，Windows 对直连域名也使用导入的主 DNS。"));
        return config;
    }

    private bool AddRule(string line, int number)
    {
        string[] fields = Values(line);
        string kind = fields[0].ToUpperInvariant();
        if (kind == "FINAL")
        {
            if (fields.Length != 2 || !Policy(fields[1], out var final))
                throw Invalid(number, L10n.Text("FINAL 需要指定 DIRECT、PROXY 或 REJECT。"));
            Final = final;
            explicitFinal = new("FINAL", PolicyName(final), line, number);
            return true;
        }

        string? field = kind switch
        {
            "DOMAIN" => "domain",
            "DOMAIN-SUFFIX" => "domain_suffix",
            "DOMAIN-KEYWORD" => "domain_keyword",
            "IP-CIDR" or "IP-CIDR6" => "ip_cidr",
            "GEOIP" => "rule_set",
            _ => null
        };
        if (field is null)
        {
            Warn(L10n.Format($"第 {number} 行 {kind} 已保留，Windows 当前不执行。"));
            return false;
        }
        bool isAddress = field is "ip_cidr" or "rule_set";
        bool noResolve = fields.Length == 4 && fields[3].Equals("no-resolve", StringComparison.OrdinalIgnoreCase);
        if (fields.Length != 3 && !(isAddress && noResolve) || fields.Length < 2 || fields[1].Length == 0)
            throw Invalid(number, L10n.Text("规则格式无效。"));
        if (!Policy(fields[2], out var policy))
        {
            Warn(L10n.Format($"第 {number} 行的策略已保留。当前支持 DIRECT、PROXY 和 REJECT。"));
            return false;
        }

        string value = fields[1].ToLowerInvariant();
        if (field is "domain" or "domain_suffix")
            value = Domain(field == "domain_suffix" ? value.TrimStart('.') : value, number);
        else if (field == "ip_cidr")
            // Some Shadowrocket exports use IP-CIDR for both IPv4 and IPv6.
            value = Cidr(value, number);
        else if (field == "rule_set")
        {
            if (value != "cn")
            {
                Warn(L10n.Format($"第 {number} 行 GEOIP 已保留，Windows 当前支持 GEOIP,CN。"));
                return false;
            }
            value = "geoip-cn";
        }
        Rules.Add(new ImportRule(field, value, policy, Resolve: isAddress && !noResolve)
        {
            Source = new(kind, PolicyName(policy), line, number)
        });
        return false;
    }

    private void AddHost(string line, int number)
    {
        var (key, value) = Assignment(line, number);
        string host = Domain(key, number);
        string[] addresses = Values(value).Select(ip => ParseIp(ip, number).ToString()).ToArray();
        if (!Hosts.TryAdd(host, addresses))
            throw Invalid(number, L10n.Text("Host 重复定义。"));
    }

    private void AddBypass(string value, string line, int number)
    {
        foreach (string item in value.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries))
        {
            int index = Bypass.Count;
            if (item.Contains('/'))
                Bypass.Add(new("ip_cidr", Cidr(item, number), RoutePolicy.Direct));
            else if (IPAddress.TryParse(item, out var address))
                Bypass.Add(new("ip_cidr", $"{address}/{(address.AddressFamily == AddressFamily.InterNetwork ? 32 : 128)}", RoutePolicy.Direct));
            else if (item.StartsWith("*.", StringComparison.Ordinal) && !item[2..].Contains('*'))
                Bypass.Add(new("domain_suffix", "." + Domain(item[2..], number), RoutePolicy.Direct));
            else if (item.Contains('*') || item.Equals("<local>", StringComparison.OrdinalIgnoreCase))
                Warn(L10n.Format($"skip-proxy 中的特殊匹配已保留。第 {number} 行仅应用域名、*. 后缀、IP 和 CIDR。"));
            else
                Bypass.Add(new("domain", Domain(item, number), RoutePolicy.Direct));
            if (Bypass.Count > index)
                Bypass[index] = Bypass[index] with { Source = new("SKIP-PROXY", "DIRECT", line, number) };
        }
    }

    internal static string TestHost(string? input)
    {
        string host = input?.Trim() ?? "";
        if (IPAddress.TryParse(host, out var address) &&
            (address.AddressFamily == AddressFamily.InterNetwork || address.ScopeId == 0))
            return address.ToString();
        try { return Domain(host, 1); }
        catch (InvalidDataException) { throw new InvalidDataException(L10n.Text("请输入有效的域名或 IP 地址。")); }
    }

    internal static string InsertRule(string text, string? type, string? value, string? policy, bool noResolve)
    {
        var original = Parse(text);
        type = type?.Trim().ToUpperInvariant();
        value = value?.Trim();
        if (type is not ("DOMAIN" or "DOMAIN-SUFFIX" or "DOMAIN-KEYWORD" or "IP-CIDR" or "GEOIP"))
            throw new InvalidDataException(L10n.Text("请选择支持的规则类型。"));
        if (policy is null || !Policy(policy.Trim(), out var routePolicy))
            throw new InvalidDataException(L10n.Text("请选择 PROXY、DIRECT 或 REJECT。"));
        if (string.IsNullOrWhiteSpace(value) || value.Length > 253 || value.Any(c => char.IsControl(c) || c is ',' or '#' or ';'))
            throw new InvalidDataException(L10n.Text("请输入一条有效的规则值。"));
        if (type == "IP-CIDR" && IPAddress.TryParse(value, out var ip))
            value = $"{ip}/{(ip.AddressFamily == AddressFamily.InterNetwork ? 32 : 128)}";
        string line = $"{type},{value},{PolicyName(routePolicy)}" + (noResolve ? ",no-resolve" : "");
        var candidate = new ShadowrocketConfiguration();
        candidate.AddRule(line, 1);
        if (candidate.Rules.Count != 1)
            throw new InvalidDataException(candidate.Warnings.FirstOrDefault() ?? L10n.Text("无法使用这条规则。"));
        if (original.Rules.FirstOrDefault() is { } first &&
            first with { Source = null } == candidate.Rules[0] with { Source = null })
            return text;

        using var reader = new StringReader(text);
        int offset = 0;
        while (reader.ReadLine() is { } raw)
        {
            int end = offset + raw.Length;
            offset = end;
            if (offset < text.Length && text[offset] == '\r')
                offset++;
            if (offset < text.Length && text[offset] == '\n')
                offset++;
            string trimmed = raw.Trim().TrimStart('\uFEFF').Trim();
            if (trimmed.StartsWith('[') && trimmed.EndsWith(']') &&
                trimmed[1..^1].Trim().Equals("rule", StringComparison.OrdinalIgnoreCase))
                return text.Insert(offset, line + text[end..offset]);
        }
        throw new InvalidDataException(L10n.Text("分流配置缺少 [Rule] 段。"));
    }

    private static string PolicyName(RoutePolicy policy) => policy.ToString().ToUpperInvariant();

    private static (string Key, string Value) Assignment(string line, int number)
    {
        int delimiter = line.IndexOf('=');
        if (delimiter < 1)
            throw Invalid(number, L10n.Text("设置需要键和值。"));
        string key = line[..delimiter].Trim().ToLowerInvariant();
        string value = line[(delimiter + 1)..].Trim();
        if (key.Length == 0 || value.Length == 0 && key != "skip-proxy")
            throw Invalid(number, L10n.Text("设置需要键和值。"));
        return (key, value);
    }

    private static bool Flag(string value, int number) =>
        bool.TryParse(value, out bool flag) ? flag : throw Invalid(number, L10n.Text("设置需要 true 或 false。"));

    private static bool Policy(string value, out RoutePolicy policy)
    {
        policy = value.ToUpperInvariant() switch
        {
            "DIRECT" => RoutePolicy.Direct, "PROXY" => RoutePolicy.Proxy, "REJECT" => RoutePolicy.Reject, _ => (RoutePolicy)(-1)
        };
        return (int)policy >= 0;
    }

    private static string Resolver(string value, int number)
    {
        if (value.Equals("system", StringComparison.OrdinalIgnoreCase))
            return "system";
        if (IPAddress.TryParse(value, out var ip))
            return ParseIp(ip.ToString(), number).ToString();
        if (Uri.TryCreate(value, UriKind.Absolute, out var uri) && uri.Scheme == "https" && uri.Host.Length > 0 &&
            uri.UserInfo.Length == 0 && uri.Query.Length == 0 && uri.Fragment.Length == 0 && uri.Port is > 0 and <= 65535)
            return uri.AbsoluteUri;
        throw Invalid(number, L10n.Text("主 DNS 需要为 system、IP 地址或 HTTPS DNS 地址。"));
    }

    private static string Domain(string value, int number)
    {
        try
        {
            string host = new IdnMapping().GetAscii(value.TrimEnd('.')).ToLowerInvariant();
            if (Uri.CheckHostName(host) == UriHostNameType.Dns)
                return host;
        }
        catch (ArgumentException) { }
        throw Invalid(number, L10n.Text("域名格式无效。"));
    }

    private static IPAddress ParseIp(string value, int number)
    {
        if (IPAddress.TryParse(value, out var ip) && (ip.AddressFamily == AddressFamily.InterNetwork || ip.ScopeId == 0))
            return ip;
        throw Invalid(number, L10n.Text("IP 地址格式无效。"));
    }

    private static string Cidr(string value, int number)
    {
        string[] pieces = value.Split('/', 2);
        IPAddress ip = ParseIp(pieces[0], number);
        int max = ip.AddressFamily == AddressFamily.InterNetwork ? 32 : 128;
        if (pieces.Length != 2 || !int.TryParse(pieces[1], NumberStyles.None, CultureInfo.InvariantCulture, out int prefix) || prefix > max)
            throw Invalid(number, L10n.Text("CIDR 地址格式无效。"));
        return $"{ip}/{prefix}";
    }

    private static string[] Values(string text) => text.Split(',', StringSplitOptions.TrimEntries);
    private void Warn(string message) { if (!warnings.Contains(message)) warnings.Add(message); }
    private static InvalidDataException Invalid(int number, string message) => new(L10n.Format($"第 {number} 行：{message}"));
}
