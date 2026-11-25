using Byway;
using System.Text;

const string export = """
[
  {
    "type": "VLESS", "title": "fixture", "host": "example.com", "port": "443",
    "tls": true, "peer": "example.com", "tlsProfile": "Safari26_3",
    "uuid": "11111111-1111-4111-8111-111111111111",
    "password": "22222222-2222-4222-8222-222222222222"
  },
  {
    "type": "VLESS", "title": "missing password", "host": "example.com", "port": 443,
    "uuid": "33333333-3333-4333-8333-333333333333"
  },
  { "type": "Subscribe", "title": "subscription" }
]
""";

string file = Path.GetTempFileName();
try
{
    File.WriteAllText(file, export);
    var batch = NodeImport.Read(file);
    if (batch.Entries.Count != 2 || batch.Subscriptions != 1)
        throw new InvalidOperationException("Expected two node results and one skipped subscription.");

    Node node = batch.Entries[0].Node ?? throw new InvalidOperationException("Valid node was rejected.");
    if (node.Outbound.GetProperty("uuid").GetString() != "22222222-2222-4222-8222-222222222222")
        throw new InvalidOperationException("The VLESS user ID must come from the exported password field.");
    if (node.Port != 443 || node.Outbound.GetProperty("tls").GetProperty("utls").GetProperty("fingerprint").GetString() != "safari")
        throw new InvalidOperationException("The export's port or Safari profile was not translated.");
    if (batch.Entries[1].Node is not null || batch.Entries[1].Error is null)
        throw new InvalidOperationException("A record ID without credentials must fail import.");
    if (!NodeImport.SameNode(node, NodeImport.Read(file).Entries[0].Node!))
        throw new InvalidOperationException("Re-importing an identical node must detect the duplicate.");
    Console.WriteLine("Shadowrocket VLESS import passed.");
}
finally
{
    File.Delete(file);
}

static string Base64(string text) => Convert.ToBase64String(Encoding.UTF8.GetBytes(text)).TrimEnd('=').Replace('+', '-').Replace('/', '_');

const string source = "https://example.com/feed?a=sample";
var link = SubscriptionLink.Parse($"sub://{Base64(source)}#%E8%AE%A2%E9%98%85");
if (link.Address.AbsoluteUri != source || link.Name != "订阅" || SubscriptionLink.Parse(source).Address != link.Address)
    throw new InvalidOperationException("Subscription address or group name was not decoded.");

const string vmess = """{"v":"2","ps":"Tokyo","add":"example.com","port":"443","id":"11111111-1111-4111-8111-111111111111","aid":"1","net":"tcp","type":"none","tls":"tls"}""";
const string invalid = """{"ps":"missing server","port":443,"id":"11111111-1111-4111-8111-111111111111","aid":1,"tls":"tls"}""";
string ss = $"ss://{Base64("aes-128-gcm:example-pass")}@example.com:8388#Example";
const string vless = "vless://11111111-1111-4111-8111-111111111111@example.com:443?security=tls&type=ws&path=%2Fws#Example";
string feed = $"profile-url=https://example.com/metadata\nvmess://{Base64(vmess)}\nvmess://{Base64(invalid)}\n{ss}\n{vless}";
var parsed = Subscription.ParseNodes(Base64(feed));
if (parsed.Nodes.Count != 3 || parsed.Skipped != 1 || parsed.Nodes[0].Outbound.GetProperty("alter_id").GetInt32() != 1 ||
    parsed.Nodes[2].Outbound.GetProperty("transport").GetProperty("path").GetString() != "/ws")
    throw new InvalidOperationException("Subscription import produced incorrect nodes.");

var updated = Subscription.ParseNodes(feed.Replace("#Example", "#Renamed")).Nodes;
updated = NodeGroups.Match(parsed.Nodes, updated);
if (!updated.Select(node => node.Id).SequenceEqual(parsed.Nodes.Select(node => node.Id)) || updated[1].Name != "Renamed" ||
    updated.Any(node => node.Outbound.GetProperty("tag").GetGuid() != node.Id))
    throw new InvalidOperationException("Refreshing a group must preserve matching node IDs and apply renamed nodes.");

string rotated = vmess.Replace("example.com", "rotated.example.com");
var rotatedNodes = NodeGroups.Match(parsed.Nodes, Subscription.ParseNodes($"vmess://{Base64(rotated)}").Nodes);
if (rotatedNodes[0].Id != parsed.Nodes[0].Id || rotatedNodes[0].Host != "rotated.example.com")
    throw new InvalidOperationException("A unique, unchanged node name must keep its ID when the provider rotates the endpoint.");
Console.WriteLine("Subscription decoding, protocol import and stable group membership passed.");

var realityNode = Subscription.ParseNodes(vless.Replace("security=tls", "security=reality&pbk=fixture")).Nodes.Single();
if (realityNode.ProtocolLabel != "VLESS · REALITY" || parsed.Nodes[0].ProtocolLabel != "VMess" ||
    parsed.Nodes[1].ProtocolLabel != "Shadowsocks" || parsed.Nodes[2].ProtocolLabel != "VLESS")
    throw new InvalidOperationException("Node protocol labels must identify supported types and REALITY separately.");

var row = new NodeRow(realityNode);
var groupOne = new NodeGroup(Guid.NewGuid(), "手动组", null, [realityNode.Id, realityNode.Id]);
var groupTwo = new NodeGroup(Guid.NewGuid(), "订阅组", source, [realityNode.Id]);
var groupIndex = NodeGroups.ByMember([groupOne, groupTwo]);
row.UpdateGroups(groupIndex[row.Node.Id]);
if (row.GroupNames != "手动组、订阅组" || !row.Groups.SequenceEqual([groupOne, groupTwo]))
    throw new InvalidOperationException("The node row must show each actual membership once.");
var renamedGroup = groupTwo with { Name = "订阅组改名" };
row.UpdateGroups(NodeGroups.ByMember([renamedGroup])[row.Node.Id]);
if (row.GroupNames != "订阅组改名")
    throw new InvalidOperationException("The node row must reflect member removal and group renames.");
row.UpdateGroups(NodeGroups.ByMember([groupOne with { Members = [parsed.Nodes[0].Id] }])[row.Node.Id]);
if (row.GroupNames != "未分组" || row.Groups.Count != 0)
    throw new InvalidOperationException("An ungrouped node must be shown separately from named memberships.");
if (row.TestAge != "—" || row.ExitDisplay != "—" || row.LastTestedAtUtc is not null)
    throw new InvalidOperationException("An untested node must not display probe data.");
row.UpdateUseStatus(active: false, selected: true);
if (row.UseStatus != "已选为出口")
    throw new InvalidOperationException("A saved outlet needs its own state when the proxy is off.");
row.UpdateUseStatus(active: true, selected: true);
if (row.UseStatus != "使用中")
    throw new InvalidOperationException("The active outlet must take precedence over the saved state.");

var testedAt = DateTimeOffset.UtcNow.AddMinutes(-3);
var trace = ProbeResult.FromResponse("colo=SEA\r\nip=203.0.113.20\r\nloc=JP\r\n", true, 123) with { CompletedAtUtc = testedAt };
row.Update(trace);
row.RefreshTestAge(testedAt.AddMinutes(3));
if (trace.ExitRegionCode != "JP" || trace.ExitRegionName is not { } region ||
    row.ExitDisplay != $"{region} · 203.0.113.20" || row.Test != "可用 · 123 ms" || row.TestAge != "3 分钟前" ||
    row.LastTestedAtUtc != testedAt || row.TestLocalTime != testedAt.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss", System.Globalization.CultureInfo.InvariantCulture))
    throw new InvalidOperationException("A trace must pair the observed IP with its reported geography and retain the completion time.");
row.RefreshTestAge(testedAt.AddHours(2));
if (row.TestAge != "2 小时前")
    throw new InvalidOperationException("The relative test time must update as the result ages.");

foreach (string code in new[] { "", "XX", "ZZ", "T1", "bad" })
{
    row.Update(ProbeResult.FromResponse($"ip=2001:db8::1\nloc={code}\n", true, 50));
    if (row.Probe?.ExitRegionCode is not null || row.ExitDisplay != "2001:db8::1")
        throw new InvalidOperationException("An unknown geography must still display the full IPv6 address.");
}
row.Update(ProbeResult.FromResponse("203.0.113.20\n", false, 51));
if (row.Probe?.ExitRegionCode is not null || row.ExitDisplay != "203.0.113.20")
    throw new InvalidOperationException("IP-only responses must remain usable.");
row.Update(ProbeResult.FromResponse("loc=JP\nip=invalid\n", true, 52));
if (row.Probe?.Succeeded != false || row.ExitDisplay != "—" || row.LastTestedAtUtc is null)
    throw new InvalidOperationException("A failed probe must clear the outlet and record when it finished.");
Console.WriteLine("Node list protocol, outlet state, exit geography and test time passed.");

Node providerNode = parsed.Nodes[0];
Node hiddenNode = parsed.Nodes[1];
var managedGroup = new NodeGroup(Guid.NewGuid(), "Managed", source, [providerNode.Id, hiddenNode.Id]);
var renamedNode = providerNode with { Name = "Locally renamed" };
managedGroup = NodeGroups.SetNodeOverride(managedGroup, providerNode, renamedNode);
managedGroup = NodeGroups.SetNodeOverride(managedGroup, hiddenNode, null);
var refresh = NodeGroups.ApplySubscription(managedGroup, [renamedNode], Subscription.ParseNodes($"vmess://{Base64(rotated)}").Nodes);
if (refresh.Nodes.Single() is not { Name: "Locally renamed", Host: "rotated.example.com" } || refresh.Nodes[0].Id != providerNode.Id)
    throw new InvalidOperationException("A local rename must survive refresh while inheriting a new provider endpoint.");
managedGroup = managedGroup with { Overrides = refresh.Overrides };
refresh = NodeGroups.ApplySubscription(managedGroup, refresh.Nodes, Subscription.ParseNodes($"vmess://{Base64(rotated)}\n{ss}").Nodes);
if (refresh.Nodes.Count != 1 || refresh.Overrides?.Find(change => change.Source.Id == hiddenNode.Id)?.Hidden != true)
    throw new InvalidOperationException("A locally deleted member must remain hidden when it returns in the subscription.");

var editedConnection = Subscription.ParseNodes($"vmess://{Base64(vmess.Replace("example.com", "local.example.com"))}").Nodes.Single()
    .WithId(providerNode.Id) with { Name = renamedNode.Name };
managedGroup = NodeGroups.SetNodeOverride(managedGroup with { Overrides = refresh.Overrides }, refresh.Nodes[0], editedConnection);
refresh = NodeGroups.ApplySubscription(managedGroup, [editedConnection], Subscription.ParseNodes(ss).Nodes);
if (refresh.Nodes.Single() is not { Name: "Locally renamed", Host: "local.example.com" } || refresh.Nodes[0].Id != providerNode.Id)
    throw new InvalidOperationException("A locally configured connection must survive disappearance of its subscribed source.");
Console.WriteLine("Subscription node edits, deletion and refresh reconciliation passed.");

var info = SubscriptionInfo.Parse([" Upload = 10; download=20; total=100; expire=1797601106 "]);
if (info is not { UploadBytes: 10, DownloadBytes: 20, TotalBytes: 100, RemainingBytes: 70 } ||
    info.ExpiresAt?.ToUnixTimeSeconds() != 1797601106)
    throw new InvalidOperationException("Subscription quota or expiry was parsed incorrectly.");
var partial = SubscriptionInfo.Parse(["upload=0; download=bad; total=100", "expire=-1"]);
if (partial is not { UploadBytes: 0, TotalBytes: 100, RemainingBytes: null, ExpiresAt: null })
    throw new InvalidOperationException("Missing quota inputs must stay unknown.");
if (SubscriptionInfo.Parse(["upload=9223372036854775807; download=9223372036854775807; total=100"])?.RemainingBytes != 0 ||
    SubscriptionInfo.Parse(["expire=9223372036854775807; something=1"]) is not null)
    throw new InvalidOperationException("Out-of-range expiry and over-quota counters must be handled.");
Console.WriteLine("Subscription account info passed.");

foreach (var node in parsed.Nodes)
{
    if (ImportCode.Parse(ShareCodes.ForNode(node)) is not ImportCode.NodeCode result || !NodeImport.SameNode(node, result.Node))
        throw new InvalidOperationException("A shared single-node link must preserve its connection parameters.");
}
var group = new NodeGroup(Guid.NewGuid(), "Sample 组", source, []);
if (ImportCode.Parse(ShareCodes.ForSubscription(group)) is not ImportCode.SubscriptionCode sharedSub ||
    sharedSub.Link.Address.AbsoluteUri != source || sharedSub.Link.Name != group.Name)
    throw new InvalidOperationException("A shared subscription must preserve its address and name.");

var random = new Random(17);
var sharingFixture = Enumerable.Range(1, 80).Select(index =>
{
    var bytes = new byte[32];
    random.NextBytes(bytes);
    return $"ss://{Base64("aes-256-gcm:" + Convert.ToHexString(bytes))}@example.com:443#Sample-{index}";
});
var manyNodes = Subscription.ParseNodes(string.Join('\n', sharingFixture)).Nodes;
string bundle = ShareCodes.ForGroup("Large 组", manyNodes);
string[] fragments = QrParts.Split(bundle);
if (fragments.Length < 2)
    throw new InvalidOperationException("Expected the large node group to require several QR codes.");
var scan = new QrParts();
string? joined = null;
foreach (string part in fragments.Reverse())
    joined = scan.Accept(part, out _);
if (joined != bundle || ImportCode.Parse(joined) is not ImportCode.GroupCode sharedGroup ||
    sharedGroup.Name != "Large 组" || sharedGroup.Nodes.Count != manyNodes.Count ||
    !sharedGroup.Nodes.Zip(manyNodes).All(pair => NodeImport.SameNode(pair.First, pair.Second)))
    throw new InvalidOperationException("Out-of-order QR scans must reconstruct all shared nodes.");
Console.WriteLine("Node, subscription and multipart group sharing passed.");

const string rulesText = """
[General]
dns-server = system
fallback-dns-server = system
prefer-ipv6 = false
skip-proxy = 192.168.0.0/16, *.local
tun-excluded-routes = 169.254.0.0/16, 192.0.2.0/24
[Rule]
DOMAIN,testflight.apple.com,PROXY
DOMAIN-SUFFIX,apple.com,DIRECT
IP-CIDR,2001:B28:F23D::/48,PROXY,no-resolve
IP-CIDR,104.16.0.0/13,DIRECT
DOMAIN-SUFFIX,whoer.net,PROXY
USER-AGENT,Line*,PROXY
FINAL,PROXY
[Host]
localhost = 127.0.0.1
[URL Rewrite]
^https?://example.net https://www.example.net 302
""";
ShadowrocketConfiguration routing = ShadowrocketConfiguration.Parse(rulesText);
if (routing.Rules.Count != 5 || routing.Bypass.Count != 2 || routing.TunExcludedRoutes.Count != 2 || routing.Strategy != "prefer_ipv4" ||
    routing.Warnings.Count != 2 || !routing.Hosts.ContainsKey("localhost"))
    throw new InvalidOperationException("Routing import must preserve supported rules and report unsupported entries.");
var compiled = System.Text.Json.JsonDocument.Parse(ProxyCoreConfiguration.Create(parsed.Nodes[0], 10001, 10002, routing, ""));
using (compiled)
{
    var compiledRules = compiled.RootElement.GetProperty("route").GetProperty("rules");
    if (compiledRules[0].GetProperty("inbound")[0].GetString() != "byway-probe" ||
        compiledRules[3].GetProperty("domain_suffix")[0].GetString() != ".local" ||
        compiledRules[4].GetProperty("domain")[0].GetString() != "testflight.apple.com" ||
        compiledRules[5].GetProperty("domain_suffix")[0].GetString() != "apple.com" ||
        compiledRules[6].GetProperty("ip_cidr")[0].GetString() != "2001:b28:f23d::/48" ||
        compiledRules[7].GetProperty("action").GetString() != "resolve" ||
        compiledRules[9].GetProperty("domain_suffix")[0].GetString() != "whoer.net")
        throw new InvalidOperationException("Routing conversion altered rule precedence or no-resolve behavior.");
}
if (!ShadowrocketConfiguration.Parse("[Rule]\nGEOIP,CN,DIRECT\nFINAL,PROXY").UsesGeoIp)
    throw new InvalidOperationException("GEOIP,CN must use the bundled country rule set.");

static void MustRejectRouting(string text)
{
    try { ShadowrocketConfiguration.Parse(text); }
    catch (InvalidDataException) { return; }
    throw new InvalidOperationException("An invalid route must not be activated.");
}
MustRejectRouting("[Rule]\nFINAL,PROXY\nDOMAIN,test.example.com,DIRECT");
MustRejectRouting("[Rule]\nIP-CIDR,10.0.0.0/33,DIRECT");
Console.WriteLine("Shadowrocket routing import, warnings, rule precedence and no-resolve checks passed.");

const string existingRules = "\uFEFF[General]\r\nskip-proxy = localhost\r\n[Rule]\r\n# keep\r\nDOMAIN-KEYWORD,example,PROXY\r\nFINAL,PROXY\r\n[Host]\r\nlocalhost = 127.0.0.1\r\n";
string updatedRules = ShadowrocketConfiguration.InsertRule(existingRules, "DOMAIN", "docs.example.com", "DIRECT", false);
if (updatedRules.Replace("DOMAIN,docs.example.com,DIRECT\r\n", "", StringComparison.Ordinal) != existingRules ||
    ShadowrocketConfiguration.InsertRule(updatedRules, "DOMAIN", "DOCS.EXAMPLE.COM.", "DIRECT", false) != updatedRules ||
    ShadowrocketConfiguration.Parse(updatedRules).Rules[0].Source is not { LineNumber: 4, Type: "DOMAIN", Policy: "DIRECT" } ||
    ShadowrocketConfiguration.TestHost(" BÜCHER.example. ") != "xn--bcher-kva.example")
    throw new InvalidOperationException("Rule insertion must preserve the original file and avoid a duplicate when retried.");
try
{
    ShadowrocketConfiguration.InsertRule(existingRules, "DOMAIN", "example.com\r\nFINAL,PROXY", "DIRECT", false);
    throw new InvalidOperationException("A new rule must not inject a second configuration line.");
}
catch (InvalidDataException) { }
var ruleMatches = new Dictionary<int, RoutingRuleMatch>();
using (var preview = System.Text.Json.JsonDocument.Parse(ProxyCoreConfiguration.Create(parsed.Nodes[0], 10101, 10102,
    ShadowrocketConfiguration.Parse(updatedRules), "", ruleTest: ruleMatches)))
{
    var rules = preview.RootElement.GetProperty("route").GetProperty("rules");
    if (ruleMatches[1].Type != "SKIP-PROXY" || ruleMatches[2].LineNumber != 4 || ruleMatches[4].Type != "FINAL" ||
        rules.EnumerateArray().Skip(1).Any(rule => rule.GetProperty("action").GetString() != "reject"))
        throw new InvalidOperationException("Rule testing must preserve rule order and stop before forwarding to the target.");
}

foreach (var node in parsed.Nodes.Take(2))
{
    using var config = System.Text.Json.JsonDocument.Parse(ProxyCoreConfiguration.Create(node, 10101, 10102,
        routing, "", capture: CaptureMode.Tun));
    var engine = config.RootElement;
    var route = engine.GetProperty("route");
    var rules = route.GetProperty("rules").EnumerateArray().ToArray();
    var whoer = rules.Single(rule => rule.TryGetProperty("domain_suffix", out var domains) && domains[0].GetString() == "whoer.net");
    var apple = rules.Single(rule => rule.TryGetProperty("domain_suffix", out var domains) && domains[0].GetString() == "apple.com");
    var tun = engine.GetProperty("inbounds").EnumerateArray().Single(inbound => inbound.GetProperty("type").GetString() == "tun");
    var exclusions = tun.GetProperty("route_exclude_address").EnumerateArray().Select(route => route.GetString()).ToArray();
    if (whoer.GetProperty("outbound").GetString() != node.Id.ToString() || !whoer.GetProperty("preserve_domain").GetBoolean() ||
        rules[^1].GetProperty("outbound").GetString() != node.Id.ToString() || !rules[^1].GetProperty("preserve_domain").GetBoolean() ||
        route.GetProperty("final").GetString() != node.Id.ToString() || apple.GetProperty("outbound").GetString() != "direct" ||
        !exclusions.Contains("192.0.2.0/24") || exclusions.Count(route => route == "169.254.0.0/16") != 1)
        throw new InvalidOperationException("Shadowrocket PROXY and FINAL must follow the current node while DIRECT and TUN exclusions are preserved.");
}

const string clashText = """
Proxy:
- { name: legacy, type: unsupported }
Rules:
- MATCH,REJECT
proxies:
- { name: Test SS, type: ss, server: 192.0.2.10, port: 443, cipher: aes-256-gcm, password: test-password, udp: true }
- name: Test VMess
  type: vmess
  server: node.example.test
  port: 443
  uuid: 00000000-0000-4000-8000-000000000001
  alterId: 1
  cipher: auto
  tls: true
  skip-cert-verify: false
  udp: false
  network: ws
  ws-opts:
    path: /tunnel
    headers: { Host: node.example.test }
proxy-groups:
- { name: Outer, type: select, proxies: [Inner, DIRECT] }
- { name: Inner, type: select, proxies: [Test SS, Test VMess, REJECT] }
hosts: { local.example.test: 127.0.0.1 }
dns:
  enable: true
  use-hosts: true
  default-nameserver: [192.0.2.1, 192.0.2.2]
  nameserver: [192.0.2.3, 'tls://dns.example.test']
  nameserver-policy: { '+.example.test': 'tcp://192.0.2.4:5353' }
rules:
- DOMAIN,local.example.test,DIRECT
- IP-CIDR,192.0.2.0/24,REJECT,no-resolve
- DST-PORT,443,Outer
- IP-CIDR6,2001:db8::/32,DIRECT
- MATCH,Outer
""";
var clashImport = new ImportedRouting(Guid.NewGuid(), "Clash test", clashText,
    Selections: new() { ["Inner"] = "Test VMess", ["Outer"] = "Inner" });
if (clashImport.Parse() is not ClashConfiguration clash || clash.Report() is not { RuleCount: 5, NodeCount: 2, GroupCount: 2, Final: "PROXY" } ||
    clash.Report().Warnings.Length != 2)
    throw new InvalidOperationException("Clash must load the lowercase fields and report their precedence.");
var selectedNode = parsed.Nodes[0];
string selectedTag = selectedNode.Id.ToString();
using (var output = System.Text.Json.JsonDocument.Parse(ProxyCoreConfiguration.Create(selectedNode, 10101, 10102, clash, "", dnsPort: 10103, lookupPort: 10104)))
{
    var root = output.RootElement;
    var compiledRoute = root.GetProperty("route");
    var compiledRules = compiledRoute.GetProperty("rules");
    var outbounds = root.GetProperty("outbounds").EnumerateArray().ToDictionary(item => item.GetProperty("tag").GetString()!);
    if (outbounds.Count != 2 || !outbounds.ContainsKey(selectedTag) || !outbounds.ContainsKey("DIRECT") ||
        compiledRoute.GetProperty("final").GetString() != selectedTag ||
        compiledRules[4].GetProperty("action").GetString() != "reject" ||
        compiledRules[5].GetProperty("port")[0].GetInt32() != 443 ||
        compiledRules[5].GetProperty("outbound").GetString() != selectedTag ||
        compiledRules[6].GetProperty("action").GetString() != "resolve" ||
        !root.GetProperty("dns").GetProperty("rules").EnumerateArray().Any(item =>
            item.TryGetProperty("match_response", out var match) && match.GetString() == "nameserver-2"))
        throw new InvalidOperationException("Clash proxy rules must use the current node and preserve ordered IP and port matches, blocking, and DNS.");
}
foreach (string legacySelection in new[] { "DIRECT", "REJECT" })
{
    var legacy = ClashConfiguration.Parse(clashText, new Dictionary<string, string>
    {
        ["Outer"] = legacySelection == "DIRECT" ? "DIRECT" : "Inner",
        ["Inner"] = "REJECT"
    });
    using var output = System.Text.Json.JsonDocument.Parse(ProxyCoreConfiguration.Create(selectedNode, 10101, 10102, legacy, "",
        dnsPort: 10103, lookupPort: 10104));
    var compiledRoute = output.RootElement.GetProperty("route");
    var rule = compiledRoute.GetProperty("rules")[5];
    if (legacy.Report().Final != legacySelection ||
        (legacySelection == "DIRECT" ? rule.GetProperty("outbound").GetString() != "DIRECT" : rule.GetProperty("action").GetString() != "reject"))
        throw new InvalidOperationException("Legacy DIRECT and REJECT choices must keep their meaning.");
}
foreach (string invalidClash in new[]
{
    clashText.Replace("proxies: [Inner, DIRECT]", "proxies: [Outer, DIRECT]"),
    clashText.Replace("DST-PORT,443,Outer", "UNSUPPORTED,443,Outer")
})
{
    try { ClashConfiguration.Parse(invalidClash); }
    catch (InvalidDataException) { continue; }
    throw new InvalidOperationException("A cyclic group or unsupported Clash rule must not be applied.");
}
Console.WriteLine("Clash YAML conversion, selection, rule order, DNS and failure checks passed.");

foreach (var (mode, expected) in new[]
{
    (RoutingMode.Direct, "DIRECT"), (RoutingMode.Global, selectedTag)
})
{
    using var config = System.Text.Json.JsonDocument.Parse(ProxyCoreConfiguration.Create(mode == RoutingMode.Direct ? null : selectedNode,
        10101, 10102, clash, "", dnsPort: 10103, lookupPort: 10104, mode: mode));
    var route = config.RootElement.GetProperty("route");
    if (route.GetProperty("final").GetString() != expected || route.GetProperty("rules").GetArrayLength() != 3 ||
        config.RootElement.GetProperty("dns").GetProperty("servers").GetArrayLength() < 4)
        throw new InvalidOperationException("Global and direct routing must override user rules while preserving DNS.");
}

using (var config = System.Text.Json.JsonDocument.Parse(ProxyCoreConfiguration.Create(selectedNode, 10101, 10102, clash, "",
    dnsPort: 10103, lookupPort: 10104, mode: RoutingMode.Global, capture: CaptureMode.Tun)))
{
    var root = config.RootElement;
    var tun = root.GetProperty("inbounds").EnumerateArray().Single(item => item.GetProperty("type").GetString() == "tun");
    var route = root.GetProperty("route");
    var captureRules = route.GetProperty("rules").EnumerateArray().Skip(3).ToArray();
    if (tun.GetProperty("address").GetArrayLength() != 2 || !tun.GetProperty("strict_route").GetBoolean() ||
        !tun.GetProperty("route_exclude_address").EnumerateArray().Any(item => item.GetString() == "100.64.0.0/10") ||
        !route.GetProperty("auto_detect_interface").GetBoolean() || route.GetProperty("final").GetString() != selectedTag ||
        captureRules[0].GetProperty("outbound").GetString() != "DIRECT" ||
        captureRules[1].GetProperty("action").GetString() != "hijack-dns" ||
        captureRules[2].GetProperty("action").GetString() != "sniff")
        throw new InvalidOperationException("TUN must capture both IP families and DNS, preserve the global outlet, and exclude private routes.");
}
Console.WriteLine("Windows TUN configuration and existing route mode compatibility passed.");

using (var proxy = new MixedListener(0))
{
    using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
    using var first = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0);
    using var second = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0);
    first.Start();
    second.Start();
    try
    {
        using var collision = new MixedListener(proxy.Port);
        throw new Exception("A competing listener must not silently share the Byway port.");
    }
    catch (InvalidOperationException error) when (error.InnerException is System.Net.Sockets.SocketException) { }

    await CheckForwarding(first, 41);
    await CheckForwarding(second, 42);

    async Task CheckForwarding(System.Net.Sockets.TcpListener backend, byte payload)
    {
        proxy.TargetPort = ((System.Net.IPEndPoint)backend.LocalEndpoint).Port;
        using var origin = new System.Net.Sockets.TcpClient();
        await origin.ConnectAsync(System.Net.IPAddress.Loopback, proxy.Port, timeout.Token);
        using var accepted = await backend.AcceptTcpClientAsync(timeout.Token);
        var stream = origin.GetStream();
        var destination = accepted.GetStream();
        byte[] value = [payload];
        await stream.WriteAsync(value, timeout.Token);
        byte[] received = new byte[1];
        await destination.ReadExactlyAsync(received, timeout.Token);
        string source = accepted.Client.RemoteEndPoint!.ToString()!;
        var local = (System.Net.IPEndPoint)origin.Client.LocalEndPoint!;
        var original = new System.Net.IPEndPoint(local.Address.MapToIPv4(), local.Port).ToString();
        if (received[0] != payload || proxy.SourceFor(source) != original)
            throw new InvalidOperationException($"The stable endpoint relayed {received[0]} from {proxy.SourceFor(source)}, expected {payload} from {original}.");
        await destination.WriteAsync(received, timeout.Token);
        await stream.ReadExactlyAsync(value, timeout.Token);
        if (value[0] != payload)
            throw new InvalidOperationException("The stable entry must relay traffic in both directions.");
    }
}
Console.WriteLine("Stable mixed entry, collision handling and route modes passed.");

TrafficHistoryChecks.Run();
PrivateNetworkChecks.Run(selectedNode);
