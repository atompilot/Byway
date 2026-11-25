using System.Text.Json;
using System.Text.Json.Nodes;

namespace Byway;

internal static class PrivateNetworkChecks
{
    internal static void Run(Node node)
    {
        const string official = "https://controlplane.tailscale.com";
        var legacy = JsonSerializer.Deserialize<PrivateNetworkSettings>(
            """
            {"Identity":"d9b9e6df-c414-4261-99be-6560b537c018","Enabled":true,"Input":{
              "Provider":"tailscale","ControlURL":"https://controlplane.tailscale.com",
              "RelayHosts":["derp.example.org"],"DeviceName":"old-device"
            }}
            """)!;
        Require(legacy.Enabled && legacy.Identity == Guid.Parse("d9b9e6df-c414-4261-99be-6560b537c018") &&
            legacy.Input.RelayMode == PrivateNetworkInput.Strict, "The persisted legacy mode and identity must survive.");

        var json = new JsonSerializerOptions(JsonSerializerDefaults.Web);
        var oldRequest = JsonSerializer.Deserialize<PrivateNetworkInput>(
            """{"provider":"tailscale","relayHosts":["Derp.Example.org."]}""", json)!.Validate(7890);
        Require(oldRequest.RelayMode == PrivateNetworkInput.Strict &&
            oldRequest.RelayHosts.SequenceEqual(["derp.example.org"]), "The old API request must remain strict.");
        var follow = JsonSerializer.Deserialize<PrivateNetworkInput>(
            """{"provider":"tailscale","relayMode":"tailscaleDefault"}""", json)!.Validate(7890);
        Require(follow.ControlURL == official && follow.RelayHosts.Length == 0, "The official mode must need no list.");
        var updated = legacy with { Input = follow };
        var restored = JsonSerializer.Deserialize<PrivateNetworkSettings>(JsonSerializer.Serialize(updated))!;
        Require(restored.Input.RelayMode == PrivateNetworkInput.TailscaleDefault && restored.Identity == legacy.Identity &&
            restored.Enabled, "The official mode must round-trip with the existing identity.");
        Reject(follow with { Provider = "headscale", ControlURL = "https://head.example.org" });
        Reject(follow with { RelayHosts = ["derp.example.org"] });
        Reject(follow with { RelayMode = "unknown" });
        Reject(oldRequest with { RelayHosts = [] });
        Reject(oldRequest with { RelayHosts = Enumerable.Range(1, 17).Select(i => $"derp{i}.example.org").ToArray() });

        string baseConfig = ProxyCoreConfiguration.Create(node, 7890, 7891, null, "",
            mode: RoutingMode.Global, capture: CaptureMode.Tun);
        foreach (var settings in new[] { legacy, updated })
        {
            var config = JsonNode.Parse(PrivateNetworkEngine.Apply(baseConfig, settings))!;
            var endpoint = config["endpoints"]![0]!;
            var route = config["route"]!;
            Require(endpoint["control_url"]!.GetValue<string>() == official &&
                route["final"]!.GetValue<string>() == node.Id.ToString(), "Private routing must preserve the proxy exit.");
            Require(route["rules"]!.AsArray().Any(rule =>
                rule?["preferred_by"]?.GetValue<string>() == PrivateNetworkSettings.Tag), "The private rule must remain active.");
            if (settings.Input.RelayMode == PrivateNetworkInput.Strict)
                Require(endpoint["byway_relays"]![0]!.GetValue<string>() == "derp.example.org" &&
                    endpoint["byway_follow_control_relays"] is null, "Legacy settings must emit the original strict list.");
            else
                Require(endpoint["byway_relays"] is null && endpoint["byway_follow_control_relays"]!.GetValue<bool>(),
                    "The official mode must explicitly enable following control.");
        }
        Console.WriteLine("Private network configuration migration, API validation and proxy routing passed.");
    }

    private static void Reject(PrivateNetworkInput input)
    {
        try { input.Validate(7890); }
        catch (InvalidDataException) { return; }
        throw new InvalidOperationException("Invalid private network configuration was accepted.");
    }

    private static void Require(bool condition, string message)
    {
        if (!condition)
            throw new InvalidOperationException(message);
    }
}

internal static class Program
{
    internal static string StatePath(string name) => Path.Combine(Path.GetTempPath(), name);
}
