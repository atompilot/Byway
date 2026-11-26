using System.Diagnostics;
using System.Net;
using System.Net.Http.Headers;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Byway;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Hosting;

internal static class DeviceApi
{
    private const int Port = 16418;
    private const string UrlFile = "url";
    private const string IpUrlFile = "ip-url";

    private static readonly JsonSerializerOptions InputOptions = new(JsonSerializerDefaults.Web)
    {
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow
    };

    internal static async Task RunAsync(string configPath, string stateDirectory)
    {
        using var config = JsonDocument.Parse(File.ReadAllBytes(configPath));
        string? token = config.RootElement.GetProperty("experimental").GetProperty("clash_api")
            .GetProperty("secret").GetString();
        if (token is null || token.Length < 32 || token.Any(char.IsWhiteSpace))
            throw new InvalidDataException("The gateway configuration has no valid API token.");

        byte[] expected = Encoding.UTF8.GetBytes("Bearer " + token);
        var lan = LanBinding.Read();
        using var core = new HttpClient(new HttpClientHandler { UseProxy = false, AllowAutoRedirect = false })
        {
            Timeout = TimeSpan.FromSeconds(2)
        };
        core.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var identity = new DeviceIdentityStore(Path.Combine(stateDirectory, "device-identity.json"),
            "linux", "Byway 网关", HardwareModel(), typeof(DeviceApi).Assembly.GetName().Version!.ToString(3));
        string? runtime = Environment.GetEnvironmentVariable("RUNTIME_DIRECTORY");
        string directUrl = $"http://{lan?.Address ?? IPAddress.Loopback}:{Port}/";
        await using var discovery = new AvahiDiscovery(identity.Read().Id, lan?.Address.ToString(), Port,
            Path.Combine(stateDirectory, "discovery-enabled"), state =>
            {
                if (!string.IsNullOrEmpty(runtime))
                    WriteRuntimeUrl(Path.Combine(runtime, UrlFile), state.PreferredUrl ?? directUrl);
            });
        var builder = WebApplication.CreateSlimBuilder();
        builder.WebHost.ConfigureKestrel(server =>
        {
            server.ListenLocalhost(Port);
            if (lan is not null) server.Listen(lan.Address, Port);
            server.Limits.MaxRequestBodySize = 4096;
        });
        await using var app = builder.Build();
        app.Use(async (context, next) =>
        {
            context.Response.Headers.CacheControl = "no-store";
            bool asset = ManagementPage.IsAsset(context.Request);
            if (!AllowedAddress(context, lan, discovery.State) || !ManagementPage.AllowsRequest(context.Request, asset))
            {
                await Results.Json(new { error = L10n.Text("此地址或来源无法访问 Byway API。") }, statusCode: 403).ExecuteAsync(context);
                return;
            }
            if (asset)
            {
                await ManagementPage.Asset(context).ExecuteAsync(context);
                return;
            }
            byte[] header = Encoding.UTF8.GetBytes(context.Request.Headers.Authorization.ToString());
            if (!CryptographicOperations.FixedTimeEquals(header, expected))
            {
                await Results.Json(new { error = L10n.Text("访问令牌无效。") }, statusCode: 401).ExecuteAsync(context);
                return;
            }
            await next(context);
        });
        app.MapGet("/v1/guide", () => Results.Text(
            "Byway Linux 热点网关\nGET /v1/device 查询设备。GET /v1/status 同样返回 deviceInfo。\n" +
            "PATCH /v1/device 使用 {\"displayName\":\"设备名称\"} 改名。用 id 区分设备。\n" +
            L10n.Text("节点管理继续使用 127.0.0.1:16417 的 Clash API。")));
        app.MapGet("/v1/device", () => Results.Json(identity.Read()));
        app.MapGet("/v1/discovery", () => Results.Json(discovery.State));
        app.MapPatch("/v1/discovery", async (HttpRequest request) =>
        {
            if (!request.HasJsonContentType())
                return Results.Json(new { error = L10n.Text("请求正文需要 application/json。") }, statusCode: 415);
            try
            {
                var input = await request.ReadFromJsonAsync<DiscoveryInput>(InputOptions, request.HttpContext.RequestAborted);
                return input?.Enabled is bool enabled ? Results.Json(discovery.SetEnabled(enabled)) :
                    Results.BadRequest(new { error = L10n.Text("请提供 enabled。") });
            }
            catch (JsonException)
            {
                return Results.BadRequest(new { error = L10n.Text("请提供包含 enabled 的 JSON 对象。") });
            }
        });
        app.MapGet("/v1/status", async (CancellationToken cancellation) =>
        {
            var (connected, currentNodeName) = await ReadCoreStatus(core, cancellation);
            return Results.Json(new { deviceInfo = identity.Read(), connected, currentNodeName, routingName = "热点代理" });
        });
        app.MapPatch("/v1/device", async (HttpRequest request) =>
        {
            if (!request.HasJsonContentType())
                return Results.Json(new { error = L10n.Text("请求正文需要 application/json。") }, statusCode: 415);
            DeviceNameInput? input;
            try { input = await request.ReadFromJsonAsync<DeviceNameInput>(InputOptions, request.HttpContext.RequestAborted); }
            catch (JsonException)
            {
                return Results.BadRequest(new { error = L10n.Text("请提供包含 displayName 的 JSON 对象。") });
            }
            if (input?.DisplayName is not string name)
                return Results.BadRequest(new { error = L10n.Text("请提供 displayName。") });
            try { return Results.Json(identity.Rename(name)); }
            catch (ArgumentException error)
            {
                return Results.Json(new { error = error.Message }, statusCode: 422);
            }
        });
        await app.StartAsync();
        if (!string.IsNullOrEmpty(runtime)) WriteRuntimeUrl(Path.Combine(runtime, IpUrlFile), directUrl);
        discovery.Start();
        await app.WaitForShutdownAsync();
    }

    private static void WriteRuntimeUrl(string path, string url)
    {
        string temp = path + ".tmp";
        try
        {
            File.WriteAllText(temp, url + "\n");
            if (OperatingSystem.IsLinux())
                File.SetUnixFileMode(temp, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.GroupRead | UnixFileMode.OtherRead);
            File.Move(temp, path, overwrite: true);
        }
        finally { File.Delete(temp); }
    }

    internal static int ShowUrl(bool openBrowser, bool ipOnly = false)
    {
        try
        {
            string directory = Environment.GetEnvironmentVariable("RUNTIME_DIRECTORY") ?? "/run/byway-device-api";
            string address = File.ReadAllText(Path.Combine(directory, ipOnly ? IpUrlFile : UrlFile)).Trim();
            if (!Uri.TryCreate(address, UriKind.Absolute, out var url) || url.Scheme != Uri.UriSchemeHttp ||
                url.Port != Port || url.AbsolutePath != "/" || !string.IsNullOrEmpty(url.UserInfo) ||
                !string.IsNullOrEmpty(url.Query) || !string.IsNullOrEmpty(url.Fragment) ||
                (!IPAddress.TryParse(url.Host, out _) && !IsDiscoveryHost(url.Host)))
                throw new InvalidDataException(L10n.Text("无法读取有效的网关网页地址。"));

            if (!openBrowser) Console.WriteLine(address);
            else
            {
                var start = new ProcessStartInfo("xdg-open") { UseShellExecute = false };
                start.ArgumentList.Add(address);
                using var browser = Process.Start(start);
            }
            return 0;
        }
        catch (Exception error) when (error is IOException or InvalidDataException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
        {
            Console.Error.WriteLine(L10n.Text("无法打开管理网页。请确认网关管理服务正在运行，或用 device-web-url 查询地址。"));
            return 1;
        }
    }

    private static bool IsDiscoveryHost(string host) =>
        host.Length == 24 && host.StartsWith("byway-", StringComparison.Ordinal) &&
        host.EndsWith(".local", StringComparison.Ordinal) && host.AsSpan(6, 12).IndexOfAnyExcept("0123456789abcdef") < 0;

    private static bool AllowedAddress(HttpContext context, LanBinding? lan, DiscoveryState discovery)
    {
        var local = context.Connection.LocalIpAddress;
        var remote = context.Connection.RemoteIpAddress;
        var host = context.Request.Host;
        if (local is null || remote is null || host.Port != Port) return false;
        if (IPAddress.IsLoopback(local))
            return IPAddress.IsLoopback(remote) &&
                (host.Host.Equals("localhost", StringComparison.OrdinalIgnoreCase) ||
                 IPAddress.TryParse(host.Host.Trim('[', ']'), out var loopback) && IPAddress.IsLoopback(loopback));
        string? publishedHost = discovery.MdnsUrl is { } url ? new Uri(url).Host : null;
        return lan is not null && lan.Address.Equals(local) && lan.Contains(remote) &&
            (host.Host == local.ToString() || string.Equals(host.Host.TrimEnd('.'), publishedHost, StringComparison.OrdinalIgnoreCase));
    }

    private static async Task<(bool Connected, string? Node)> ReadCoreStatus(HttpClient core, CancellationToken cancellation)
    {
        try
        {
            using var response = await core.GetAsync("http://127.0.0.1:16417/proxies/byway", cancellation);
            if (!response.IsSuccessStatusCode) return (false, null);
            using var body = JsonDocument.Parse(await response.Content.ReadAsStreamAsync(cancellation));
            string? node = body.RootElement.TryGetProperty("now", out var value) && value.ValueKind == JsonValueKind.String
                ? value.GetString() : null;
            return (true, node?.StartsWith("node:", StringComparison.Ordinal) == true ? node[5..] : node);
        }
        catch (HttpRequestException) { return (false, null); }
        catch (TaskCanceledException) when (!cancellation.IsCancellationRequested) { return (false, null); }
        catch (JsonException) { return (false, null); }
    }

    private sealed record LanBinding(IPAddress Address, IPAddress Mask)
    {
        internal static LanBinding? Read()
        {
            string? setting = Environment.GetEnvironmentVariable("BYWAY_LAN_IP");
            if (string.IsNullOrWhiteSpace(setting)) return null;
            if (!IPAddress.TryParse(setting.Trim(), out var address) || !IsPrivateIPv4(address))
                throw new InvalidDataException(L10n.Text("BYWAY_LAN_IP 需要是网关上的私有 IPv4 地址。"));
            var entry = NetworkInterface.GetAllNetworkInterfaces()
                .Where(adapter => adapter.OperationalStatus == OperationalStatus.Up)
                .SelectMany(adapter => adapter.GetIPProperties().UnicastAddresses)
                .FirstOrDefault(candidate => candidate.Address.Equals(address));
            return entry?.IPv4Mask is { } mask
                ? new(address, mask)
                : throw new InvalidDataException(L10n.Text("BYWAY_LAN_IP 当前不在可用的网关接口上。"));
        }

        internal bool Contains(IPAddress peer)
        {
            if (!IsPrivateIPv4(peer)) return false;
            byte[] local = Address.GetAddressBytes(), remote = peer.GetAddressBytes(), mask = Mask.GetAddressBytes();
            return Enumerable.Range(0, 4).All(index => (local[index] & mask[index]) == (remote[index] & mask[index]));
        }

        private static bool IsPrivateIPv4(IPAddress address)
        {
            if (address.AddressFamily != AddressFamily.InterNetwork) return false;
            byte[] bytes = address.GetAddressBytes();
            return bytes[0] == 10 || bytes[0] == 172 && bytes[1] is >= 16 and <= 31 || bytes[0] == 192 && bytes[1] == 168;
        }
    }

    private static string? HardwareModel()
    {
        foreach (string path in new[] { "/sys/devices/virtual/dmi/id/product_name", "/proc/device-tree/model" })
        {
            try
            {
                string model = File.ReadAllText(path).TrimEnd('\0', '\n', '\r').Trim();
                if (model.Length > 0) return model;
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
        return null;
    }
}
