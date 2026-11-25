using System.Diagnostics;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Server.Kestrel.Core;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

namespace Byway;

internal sealed class AiServer(Func<HttpContext, bool, Task<IResult>> handle, string token, AiCallLog calls) : IDisposable
{
    internal const int LocalPort = 8766;
    internal const int LanPort = 8767;
    internal const string LocalAddress = "http://127.0.0.1:8766";
    internal const int ImageLimit = 20 * 1024 * 1024;
    private static readonly string? LanHostName = GetLanHostName();
    private volatile string accessToken = token;
    private WebApplication? local;
    private WebApplication? lan;
    private bool disposed;
    private readonly WindowsDiscovery discovery = new();

    internal DiscoveryState Discovery => discovery.State;
    internal void UpdateDiscovery(bool enabled, Guid? id)
    {
        var target = LanReady ? Subnets().OrderByDescending(network => network.HasGateway).FirstOrDefault() : null;
        discovery.Update(enabled, id, target?.Address, target?.Index ?? 0, LanPort, LanReady, LanHostName);
    }

    internal bool LocalReady => local is not null;
    internal bool LanReady => lan is not null;
    internal string Token { get => accessToken; set => accessToken = value; }

    internal async Task StartLocalAsync()
    {
        if (local is null)
            local = await StartAsync(false);
    }

    internal async Task SetLanAsync(bool enabled)
    {
        if (enabled && lan is null)
            lan = await StartAsync(true);
        else if (!enabled && lan is { } server)
        {
            lan = null;
            discovery.Dispose();
            await StopAsync(server);
        }
    }

    internal static string[] LanAddresses() => Subnets().Select(network => $"http://{network.Address}:{LanPort}").Distinct().ToArray();

    private static string? GetLanHostName()
    {
        string name = Environment.MachineName.ToLowerInvariant();
        return name.Length is > 0 and <= 63 && !name.StartsWith('-') && !name.EndsWith('-') &&
            name.All(character => char.IsAsciiLetterOrDigit(character) || character == '-')
            ? $"{name}.local"
            : null;
    }

    internal bool MatchesToken(HttpRequest request)
    {
        string authorization = request.Headers.Authorization.ToString();
        const string prefix = "Bearer ";
        string expected = accessToken;
        return authorization.StartsWith(prefix, StringComparison.OrdinalIgnoreCase) && authorization.Length == prefix.Length + expected.Length
            && CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(authorization[prefix.Length..]), Encoding.ASCII.GetBytes(expected));
    }

    private async Task<WebApplication> StartAsync(bool isLan)
    {
        var builder = WebApplication.CreateSlimBuilder(new WebApplicationOptions
        {
            Args = [], ContentRootPath = AppContext.BaseDirectory, ApplicationName = typeof(AiServer).Assembly.GetName().Name
        });
        builder.Logging.ClearProviders();
        builder.WebHost.ConfigureKestrel(kestrel =>
        {
            kestrel.AddServerHeader = false;
            kestrel.Limits.MaxRequestBodySize = ImageLimit;
            kestrel.Limits.MaxConcurrentConnections = 32;
            kestrel.Limits.RequestHeadersTimeout = TimeSpan.FromSeconds(8);
            kestrel.Limits.KeepAliveTimeout = TimeSpan.FromSeconds(20);
            kestrel.Listen(isLan ? IPAddress.Any : IPAddress.Loopback, isLan ? LanPort : LocalPort,
                endpoint => endpoint.Protocols = HttpProtocols.Http1);
        });
        builder.Services.ConfigureHttpJsonOptions(options => options.SerializerOptions.MaxDepth = 32);
        var app = builder.Build();
        app.Run(context => RespondAsync(context, isLan));
        try
        {
            await app.StartAsync();
            if (disposed)
                throw new ObjectDisposedException(nameof(AiServer));
            return app;
        }
        catch
        {
            await app.DisposeAsync();
            throw;
        }
    }

    private async Task RespondAsync(HttpContext context, bool isLan)
    {
        DateTimeOffset startedAt = DateTimeOffset.Now;
        long start = Stopwatch.GetTimestamp();
        bool authorized = false;
        context.Response.Headers.CacheControl = "no-store";
        try
        {
            HttpRequest request = context.Request;
            bool asset = ManagementPage.IsAsset(request);
            if (!AllowedAddress(context, isLan) || !ManagementPage.AllowsRequest(request, asset))
                throw new ApiError(403, "此地址或来源无法访问 Byway API。");
            if (asset)
            {
                await ManagementPage.Asset(context).ExecuteAsync(context);
                return;
            }
            if (!MatchesToken(request))
            {
                context.Response.Headers.WWWAuthenticate = "Bearer";
                throw new ApiError(401, "请提供有效的 Byway 访问令牌。");
            }
            authorized = true;
            await (await handle(context, isLan)).ExecuteAsync(context);
        }
        catch (OperationCanceledException) when (context.RequestAborted.IsCancellationRequested) { }
        catch (Exception error) when (!context.Response.HasStarted)
        {
            var (status, message) = error switch
            {
                ApiError failure => (failure.Status, failure.Message),
                Microsoft.AspNetCore.Http.BadHttpRequestException failure => (failure.StatusCode, "HTTP 请求无法读取。"),
                JsonException => (400, "JSON 正文或字段格式无效。"),
                InvalidDataException => (422, error.Message),
                InvalidOperationException => (409, error.Message),
                TimeoutException => (504, "操作超时。"),
                _ => (500, "操作失败，请查询 Byway 当前状态。")
            };
            await Results.Json(new { error = message }, statusCode: status).ExecuteAsync(context);
        }
        finally
        {
            string source = isLan ? $"局域网 · {context.Connection.RemoteIpAddress}" : "本机";
            int status = context.RequestAborted.IsCancellationRequested ? 499 : context.Response.StatusCode;
            calls.Record(startedAt, source, context.Request.Method, authorized ? context.Request.Path.Value : null,
                status, (long)Stopwatch.GetElapsedTime(start).TotalMilliseconds);
        }
    }

    private bool AllowedAddress(HttpContext context, bool isLan)
    {
        var localAddress = context.Connection.LocalIpAddress;
        var remoteAddress = context.Connection.RemoteIpAddress;
        var host = context.Request.Host;
        if (localAddress is null || remoteAddress is null || host.Port != (isLan ? LanPort : LocalPort))
            return false;
        if (!isLan)
            return IPAddress.IsLoopback(remoteAddress) &&
                (host.Host == "127.0.0.1" || host.Host.Equals("localhost", StringComparison.OrdinalIgnoreCase));

        // Allow only our own mDNS name. Never resolve a hostname supplied by the client.
        string hostName = host.Host;
        string normalizedHost = hostName.TrimEnd('.');
        var published = Discovery.MdnsUrl is { } url ? new Uri(url).Host : null;
        bool targetsThisDevice = IPAddress.TryParse(hostName, out var requested)
            ? requested.Equals(localAddress)
            : string.Equals(normalizedHost, published, StringComparison.OrdinalIgnoreCase) ||
              string.Equals(normalizedHost, LanHostName, StringComparison.OrdinalIgnoreCase);
        return targetsThisDevice &&
            Subnets().Any(network => network.Address.Equals(localAddress) && network.Contains(remoteAddress));
    }

    private static List<Subnet> Subnets()
    {
        NetworkInterface[] adapters;
        try { adapters = NetworkInterface.GetAllNetworkInterfaces(); }
        catch (NetworkInformationException) { return []; }

        List<Subnet> subnets = [];
        foreach (var adapter in adapters)
        {
            try
            {
                if (adapter.OperationalStatus != OperationalStatus.Up ||
                    adapter.NetworkInterfaceType is not (NetworkInterfaceType.Ethernet or NetworkInterfaceType.Wireless80211
                        or NetworkInterfaceType.GigabitEthernet or NetworkInterfaceType.FastEthernetFx or NetworkInterfaceType.FastEthernetT) ||
                    !adapter.Supports(NetworkInterfaceComponent.IPv4))
                    continue;

                var properties = adapter.GetIPProperties();
                uint index = (uint)(properties.GetIPv4Properties()?.Index ?? 0);
                bool hasGateway = properties.GatewayAddresses.Any(gateway => PrivateIPv4(gateway.Address));
                foreach (var item in properties.UnicastAddresses)
                    if (PrivateIPv4(item.Address) && item.IPv4Mask is { } mask)
                        subnets.Add(new(item.Address, mask, index, hasGateway));
            }
            catch (NetworkInformationException)
            {
                // Windows may change an adapter's addresses while discovery is enumerating it.
            }
        }
        return subnets;
    }

    private static bool PrivateIPv4(IPAddress address)
    {
        if (address.AddressFamily != AddressFamily.InterNetwork)
            return false;
        byte[] bytes = address.GetAddressBytes();
        return bytes[0] == 10 || bytes[0] == 172 && bytes[1] is >= 16 and <= 31 || bytes[0] == 192 && bytes[1] == 168;
    }

    private sealed record Subnet(IPAddress Address, IPAddress Mask, uint Index, bool HasGateway)
    {
        internal bool Contains(IPAddress peer)
        {
            if (!PrivateIPv4(peer))
                return false;
            var local = Address.GetAddressBytes();
            var remote = peer.GetAddressBytes();
            var mask = Mask.GetAddressBytes();
            return Enumerable.Range(0, 4).All(index => (local[index] & mask[index]) == (remote[index] & mask[index]));
        }
    }

    private static async Task StopAsync(WebApplication app)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(2));
        try { await app.StopAsync(timeout.Token); }
        catch (OperationCanceledException) { }
        finally { await app.DisposeAsync(); }
    }

    public void Dispose()
    {
        disposed = true;
        discovery.Dispose();
        if (local is { } localServer)
            _ = Task.Run(() => StopAsync(localServer));
        if (lan is { } lanServer)
            _ = Task.Run(() => StopAsync(lanServer));
    }
}

internal sealed class ApiError(int status, string message) : Exception(message)
{
    internal int Status { get; } = status;
}
