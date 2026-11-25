using System.Text.Json;
using System.Text.Json.Nodes;
using Byway;

if (args is ["serve-device-api", var configPath, var stateDirectory])
{
    await DeviceApi.RunAsync(configPath, stateDirectory);
    return 0;
}

if (args is ["device-web-url"])
    return DeviceApi.ShowUrl(openBrowser: false);

if (args is ["device-web-url", "--ip"])
    return DeviceApi.ShowUrl(openBrowser: false, ipOnly: true);

if (args is ["open-device-web"])
    return DeviceApi.ShowUrl(openBrowser: true);

if (args.Length != 2)
{
    Console.Error.WriteLine("Usage: Byway.Gateway <Shadowrocket node export.json> <default node name>");
    return 2;
}

try
{
    string? token = Environment.GetEnvironmentVariable("BYWAY_API_TOKEN");
    if (token is null || token.Length < 32 || token.Any(char.IsWhiteSpace))
        throw new InvalidDataException("Set BYWAY_API_TOKEN to a private token of at least 32 characters.");

    List<Node> nodes = NodeImport.Read(args[0]).Entries
        .Select(entry => entry.Node).OfType<Node>().ToList();
    if (nodes.Count == 0 || !nodes.Any(node => node.Name == args[1]))
        throw new InvalidDataException("The requested node was not found among the supported VLESS entries.");
    string[] tags = nodes.Select(node => $"node:{node.Name}").ToArray();
    if (tags.Distinct(StringComparer.Ordinal).Count() != tags.Length)
        throw new InvalidDataException("Give each exported node a unique name before importing.");

    List<object> outbounds =
    [
        new
        {
            type = "selector", tag = "byway", outbounds = tags,
            @default = $"node:{args[1]}", interrupt_exist_connections = true
        }
    ];
    foreach (var node in nodes)
    {
        var outbound = JsonObject.Create(node.Outbound)!;
        outbound["tag"] = $"node:{node.Name}";
        outbounds.Add(outbound);
    }

    var configuration = new
    {
        log = new { level = "warn" },
        dns = new
        {
            servers = new object[]
            {
                new { type = "local", tag = "bootstrap" },
                new
                {
                    type = "https", tag = "hotspot-dns", server = "1.1.1.1", detour = "byway",
                    tls = new { enabled = true, server_name = "cloudflare-dns.com" }
                }
            },
            final = "hotspot-dns", strategy = "ipv4_only"
        },
        inbounds = new[]
        {
            new { type = "tproxy", tag = "hotspot", listen = "0.0.0.0", listen_port = 16415 },
            new { type = "mixed", tag = "probe", listen = "127.0.0.1", listen_port = 16416 }
        },
        outbounds,
        route = new
        {
            rules = new object[]
            {
                new { inbound = "hotspot", port = 53, action = "hijack-dns" },
                new { inbound = "hotspot", ip_is_private = true, action = "reject" }
            },
            final = "byway", default_domain_resolver = "bootstrap"
        },
        experimental = new
        {
            cache_file = new { enabled = true, path = "/var/lib/byway-hotspot/cache.db" },
            clash_api = new { external_controller = "127.0.0.1:16417", secret = token }
        }
    };

    Console.WriteLine(JsonSerializer.Serialize(configuration, new JsonSerializerOptions { WriteIndented = true }));
    return 0;
}
catch (Exception error) when (error is InvalidDataException or IOException or UnauthorizedAccessException or JsonException)
{
    Console.Error.WriteLine(error is InvalidDataException ? error.Message : "The node export could not be read.");
    return 1;
}
