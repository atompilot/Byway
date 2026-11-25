using System.Diagnostics;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Byway;

internal sealed class Core : IDisposable
{
    private static readonly string Executable = Path.Combine(AppContext.BaseDirectory, "sing-box.exe");
    private static readonly string GeoIp = Path.Combine(AppContext.BaseDirectory, "geoip-cn.srs");
    private static readonly Node ValidationNode = new(Guid.Empty, "", "", 0,
        JsonSerializer.SerializeToElement(new { type = "direct", tag = Guid.Empty.ToString() }));
    private static readonly Regex RuleTestMatch = new(@"match\[(\d+)\].*=> reject\b", RegexOptions.CultureInvariant);
    private static readonly HttpClient TrafficHttp = new(new SocketsHttpHandler { UseProxy = false })
    {
        Timeout = TimeSpan.FromSeconds(2)
    };
    private static readonly HttpClient PrivateHttp = new(new SocketsHttpHandler { UseProxy = false })
    {
        Timeout = TimeSpan.FromSeconds(8)
    };
    private readonly Process process;
    private readonly Job job;
    private readonly TrafficEndpoint? telemetry;
    private readonly int probePort;
    internal Node? Source { get; }
    internal CaptureMode Capture { get; }
    internal int Port { get; }
    internal int Pid => process.Id;
    internal long StartTime => process.StartTime.ToFileTimeUtc();
    internal bool Running => !process.HasExited;
    internal string Endpoint => $"127.0.0.1:{Port}";

    private Core(Process process, Job job, Node? source, int port, int probePort, TrafficEndpoint? telemetry, CaptureMode capture)
    {
        this.process = process;
        this.job = job;
        this.telemetry = telemetry;
        Source = source;
        this.probePort = probePort;
        Port = port;
        Capture = capture;
    }

    internal static async Task<bool> CheckAsync(Node? node, IRoutingConfiguration? routing = null)
    {
        using Core core = await LaunchAsync(node, "check", 1, 2, 3, 4, null, routing, RoutingMode.Rule);
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(8));
        await core.process.WaitForExitAsync(timeout.Token);
        return core.process.ExitCode == 0;
    }

    internal static Task<bool> CheckRoutingAsync(IRoutingConfiguration routing) => CheckAsync(ValidationNode, routing);

    internal static async Task<RoutingRuleMatch> TestRuleAsync(ShadowrocketConfiguration? routing, string host)
    {
        int port = FreePort();
        Dictionary<int, RoutingRuleMatch> sources = [];
        string configuration = ProxyCoreConfiguration.Create(ValidationNode, port, port, routing, GeoIp, ruleTest: sources);
        var matched = new TaskCompletionSource<RoutingRuleMatch>(TaskCreationOptions.RunContinuationsAsynchronously);
        using var core = await StartProcessAsync(configuration, "run", null, port, port, null, CaptureMode.SystemProxy,
            null, line =>
            {
                if (line is null)
                    return;
                var match = RuleTestMatch.Match(line);
                if (match.Success && int.TryParse(match.Groups[1].Value, out int index) && sources.TryGetValue(index, out var source))
                    matched.TrySetResult(source);
            });
        await core.WaitForReadyAsync();
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(8));
        using var client = new TcpClient();
        try
        {
            await client.ConnectAsync(IPAddress.Loopback, port, deadline.Token);
            using var stream = client.GetStream();
            string authority = host.Contains(':') ? $"[{host}]:443" : $"{host}:443";
            await stream.WriteAsync(Encoding.ASCII.GetBytes($"CONNECT {authority} HTTP/1.1\r\nHost: {authority}\r\n\r\n"), deadline.Token);
            return await matched.Task.WaitAsync(deadline.Token);
        }
        catch (OperationCanceledException)
        {
            throw new InvalidOperationException("未取得规则测试结果。请检查域名的 DNS 解析后重试。");
        }
    }

    internal static async Task<Core> StartAsync(Node? node, bool collectTraffic = false, IRoutingConfiguration? routing = null,
        RoutingMode mode = RoutingMode.Rule, EngineDiagnostics? diagnostics = null,
        CaptureMode capture = CaptureMode.SystemProxy, PrivateNetworkSettings? privateNetwork = null)
    {
        int port = FreePort();
        int probe = routing is null ? port : FreePort(port);
        int dns = routing is ClashConfiguration ? FreeUdpPort(0) : 0;
        int lookup = routing is ClashConfiguration ? FreeUdpPort(dns) : 0;
        TrafficEndpoint? traffic = collectTraffic ? new(FreePort(port, probe), RandomNumberGenerator.GetHexString(32)) : null;

        Core core = await LaunchAsync(node, "run", port, probe, dns, lookup, traffic, routing, mode, diagnostics, capture, privateNetwork);
        try
        {
            await core.WaitForReadyAsync();
            return core;
        }
        catch
        {
            core.Dispose();
            throw;
        }
    }

    private async Task WaitForReadyAsync()
    {
        for (int attempt = 0; attempt < 60 && Running; attempt++)
        {
            using var socket = new TcpClient();
            try
            {
                await socket.ConnectAsync(IPAddress.Loopback, Port).WaitAsync(TimeSpan.FromMilliseconds(150));
                if (Running && (Capture != CaptureMode.Tun || NetworkInterface.GetAllNetworkInterfaces().Any(adapter =>
                    adapter.Name == ProxyCoreConfiguration.TunInterface && adapter.OperationalStatus == OperationalStatus.Up &&
                    adapter.GetIPProperties().UnicastAddresses.Any(address => address.Address.ToString() == "198.18.0.1"))))
                    return;
            }
            catch (SocketException) { }
            catch (TimeoutException) { }
            await Task.Delay(60);
        }
        throw new InvalidOperationException(Capture == CaptureMode.Tun
            ? "全流量网卡未能启动，请检查管理员权限和内核日志。" : "代理内核未能监听本机端口。");
    }

    internal async Task<TrafficSample?> ReadTrafficAsync()
    {
        try
        {
            using var json = await ReadConnectionStateAsync();
            if (json is null)
                return null;
            var root = json.RootElement;
            return new(root.GetProperty("uploadTotal").GetInt64(), root.GetProperty("downloadTotal").GetInt64(),
                root.GetProperty("connections") is { ValueKind: JsonValueKind.Array } connections ? connections.GetArrayLength() : 0,
                Stopwatch.GetTimestamp(), DateTimeOffset.UtcNow);
        }
        catch (Exception error) when (error is InvalidOperationException or KeyNotFoundException or FormatException) { return null; }
    }

    internal async Task<EngineConnection[]?> ReadConnectionsAsync()
    {
        using var state = await ReadConnectionStateAsync();
        if (state is null)
            return null;
        if (!state.RootElement.TryGetProperty("connections", out var list) || list.ValueKind != JsonValueKind.Array)
            return [];

        var result = new List<EngineConnection>();
        string? nodeTag = Source?.Id.ToString();
        foreach (var row in list.EnumerateArray())
        {
            if (!Guid.TryParse(Field(row, "id"), out var id) || !row.TryGetProperty("metadata", out var metadata))
                continue;
            string[] chain = row.TryGetProperty("chains", out var values) && values.ValueKind == JsonValueKind.Array
                ? values.EnumerateArray().Where(value => value.ValueKind == JsonValueKind.String)
                    .Select(value => value.GetString()!).ToArray() : [];
            string host = Field(metadata, "host");
            if (host.Length == 0)
                host = Field(metadata, "destinationIP");
            if (host.Length == 0)
                host = Field(metadata, "destination");
            string rule = Field(row, "rule");
            if (nodeTag is not null)
                rule = rule.Replace($"route({nodeTag})", "route(PROXY)", StringComparison.Ordinal)
                    .Replace($"route({nodeTag},", "route(PROXY,", StringComparison.Ordinal);
            result.Add(new(id, JoinEndpoint(Field(metadata, "sourceIP"), Field(metadata, "sourcePort")),
                JoinEndpoint(host, Field(metadata, "destinationPort")), Field(metadata, "network"),
                rule, string.Join(" → ", chain.Reverse().Select(ExitName)), ExitName(chain.FirstOrDefault() ?? ""),
                Number(row, "upload"), Number(row, "download")));
        }
        return [.. result];

        string ExitName(string tag) => Source is { } node && tag == nodeTag ? node.Name : tag;

        static string Field(JsonElement obj, string key) => obj.ValueKind == JsonValueKind.Object && obj.TryGetProperty(key, out var value)
            ? value.ValueKind is JsonValueKind.String or JsonValueKind.Number ? value.ToString() : "" : "";
        static long Number(JsonElement obj, string key) => obj.TryGetProperty(key, out var value) &&
            value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out long n) ? n : 0;
        static string JoinEndpoint(string host, string port) => host.Length == 0 || port.Length == 0 ? host :
            host.Contains(':') ? $"[{host}]:{port}" : $"{host}:{port}";
    }

    internal async Task<bool> CloseConnectionsAsync(Guid? id)
    {
        if (telemetry is null)
            return false;
        using var request = ControllerRequest(HttpMethod.Delete, id.HasValue ? $"/connections/{id}" : "/connections");
        using var response = await TrafficHttp.SendAsync(request);
        return response.IsSuccessStatusCode;
    }

    private async Task<JsonDocument?> ReadConnectionStateAsync()
    {
        if (telemetry is null)
            return null;
        using var request = ControllerRequest(HttpMethod.Get, "/connections");
        try
        {
            using var response = await TrafficHttp.SendAsync(request);
            if (!response.IsSuccessStatusCode)
                return null;
            using var stream = await response.Content.ReadAsStreamAsync();
            return await JsonDocument.ParseAsync(stream);
        }
        catch (Exception error) when (error is HttpRequestException or OperationCanceledException or JsonException or IOException)
        {
            return null;
        }
    }

    private HttpRequestMessage ControllerRequest(HttpMethod method, string path)
    {
        var request = new HttpRequestMessage(method, $"http://{telemetry!.Address}{path}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", telemetry.Token);
        return request;
    }

    internal async Task<T> PrivateNetworkAsync<T>(string? action = null, string? value = null)
    {
        if (telemetry is null || !Running)
            throw new InvalidOperationException("私网尚未连接。");
        using var request = ControllerRequest(action is null ? HttpMethod.Get : HttpMethod.Post, "/byway/private-network");
        if (action is not null)
            request.Content = new StringContent(JsonSerializer.Serialize(new { action, value }), Encoding.UTF8, "application/json");
        try
        {
            using var response = await PrivateHttp.SendAsync(request);
            if (!response.IsSuccessStatusCode)
                throw new InvalidOperationException(action == "probe" ? "设备未响应或私网尚未就绪。" : "私网操作未完成。");
            await using var stream = await response.Content.ReadAsStreamAsync();
            return await JsonSerializer.DeserializeAsync<T>(stream, JsonSerializerOptions.Web)
                ?? throw new InvalidDataException("私网状态暂不可用。");
        }
        catch (TaskCanceledException)
        {
            throw new InvalidOperationException("私网操作超时。");
        }
    }

    private static int FreePort(params int[] excluded)
    {
        int port;
        do
        {
            var listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            try { port = ((IPEndPoint)listener.LocalEndpoint).Port; }
            finally { listener.Stop(); }
        } while (excluded.Contains(port));
        return port;
    }

    private static int FreeUdpPort(int excluded)
    {
        int port;
        do
        {
            using var listener = new UdpClient(new IPEndPoint(IPAddress.Loopback, 0));
            port = ((IPEndPoint)listener.Client.LocalEndPoint!).Port;
        } while (port == excluded);
        return port;
    }

    internal async Task<ProbeResult> ProbeAsync(bool fallback = false, bool throughCapture = false,
        CancellationToken cancellationToken = default)
    {
        using var handler = new SocketsHttpHandler
        {
            UseProxy = !throughCapture,
            Proxy = throughCapture ? null : new WebProxy($"http://127.0.0.1:{probePort}"),
            AllowAutoRedirect = false
        };
        using var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(9) };
        using var completed = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var cloudflare = DetectExitAsync("https://www.cloudflare.com/cdn-cgi/trace", cloudflareTrace: true);
        if (!fallback)
            return await cloudflare;

        var ipify = DetectExitAsync("https://api64.ipify.org/", cloudflareTrace: false);
        var first = await Task.WhenAny(cloudflare, ipify);
        var result = await first;
        if (!result.Succeeded)
            return await (first == cloudflare ? ipify : cloudflare);
        await completed.CancelAsync();
        return result;

        async Task<ProbeResult> DetectExitAsync(string url, bool cloudflareTrace)
        {
            try
            {
                var timer = Stopwatch.StartNew();
                string text = await client.GetStringAsync(url, completed.Token);
                return ProbeResult.FromResponse(text, cloudflareTrace, timer.ElapsedMilliseconds);
            }
            catch (OperationCanceledException) { return new(null, null, "HTTPS 探测超时"); }
            catch (HttpRequestException) { return new(null, null, "HTTPS 连接失败"); }
        }
    }

    private static async Task<Core> LaunchAsync(Node? node, string verb, int port, int probePort, int dnsPort, int lookupPort,
        TrafficEndpoint? telemetry, IRoutingConfiguration? routing, RoutingMode mode,
        EngineDiagnostics? diagnostics = null, CaptureMode capture = CaptureMode.SystemProxy,
        PrivateNetworkSettings? privateNetwork = null)
    {
        string configuration = ProxyCoreConfiguration.Create(node, port, probePort, routing, GeoIp, telemetry?.Address,
            telemetry?.Token, dnsPort, lookupPort, mode, capture);
        if (capture == CaptureMode.Tun && privateNetwork is not null)
            configuration = PrivateNetworkEngine.Apply(configuration, privateNetwork);
        return await StartProcessAsync(configuration, verb, mode == RoutingMode.Direct ? null : node,
            port, probePort, telemetry, capture, diagnostics);
    }

    private static async Task<Core> StartProcessAsync(string configuration, string verb, Node? node, int port, int probePort,
        TrafficEndpoint? telemetry, CaptureMode capture, EngineDiagnostics? diagnostics, Action<string?>? trace = null)
    {
        var info = new ProcessStartInfo(Executable)
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardInput = true, StandardInputEncoding = new UTF8Encoding(false),
            RedirectStandardError = true, RedirectStandardOutput = true
        };
        foreach (var argument in new[] { verb, "-c", "stdin" })
            info.ArgumentList.Add(argument);

        var job = new Job();
        Process? process = null;
        try
        {
            process = Process.Start(info) ?? throw new InvalidOperationException("无法启动 sing-box。");
            job.Attach(process);
            if (diagnostics is not null)
            {
                string[] secrets = EngineDiagnostics.Redactions(configuration);
                process.ErrorDataReceived += (_, args) => diagnostics.Read(args.Data, secrets);
                process.OutputDataReceived += (_, args) => diagnostics.Read(args.Data, secrets);
            }
            if (trace is not null)
            {
                process.ErrorDataReceived += (_, args) => trace(args.Data);
                process.OutputDataReceived += (_, args) => trace(args.Data);
            }
            process.BeginErrorReadLine();
            process.BeginOutputReadLine();
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
            await process.StandardInput.WriteAsync(configuration.AsMemory(), timeout.Token);
            process.StandardInput.Close();
            return new(process, job, node, port, probePort, telemetry, capture);
        }
        catch
        {
            if (process is { HasExited: false })
                process.Kill();
            process?.Dispose();
            job.Dispose();
            throw;
        }
    }

    public void Dispose()
    {
        job.Dispose();
        if (Capture == CaptureMode.Tun)
            process.WaitForExit(3000);
        process.Dispose();
    }

    private sealed record TrafficEndpoint(int Port, string Token)
    {
        internal string Address => $"127.0.0.1:{Port}";
    }
}

internal sealed record TrafficSample(long Upload, long Download, int Connections, long Timestamp, DateTimeOffset CapturedAtUtc);
