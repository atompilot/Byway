using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Byway;

internal sealed record SubscriptionLink(Uri Address, string Name)
{
    internal static SubscriptionLink Parse(string input)
    {
        string text = input.Trim();
        string name = "";
        if (text.StartsWith("sub://", StringComparison.OrdinalIgnoreCase))
        {
            string[] parts = text[6..].Split('#', 2);
            text = Subscription.Decode(parts[0]) ?? throw new InvalidDataException("订阅链接的 Base64 地址无法读取。");
            if (parts.Length == 2)
                name = Uri.UnescapeDataString(parts[1]);
        }

        if (!Uri.TryCreate(text, UriKind.Absolute, out var url) || url.Scheme != Uri.UriSchemeHttps ||
            url.UserInfo.Length != 0 || url.Host.Length == 0)
            throw new InvalidDataException("请输入 sub:// 或 HTTPS 订阅链接。");

        if (name.Length == 0)
            name = Uri.UnescapeDataString(url.Fragment.TrimStart('#'));
        var address = new UriBuilder(url) { Fragment = "" }.Uri;
        return new(address, Subscription.SafeName(name, address.IdnHost));
    }
}

internal sealed record SubscriptionNodes(List<Node> Nodes, int Skipped, SubscriptionInfo? Info = null);

internal static class Subscription
{
    private const int MaxBytes = 4 * 1024 * 1024;
    private static readonly HttpClient Download = new(new SocketsHttpHandler
    {
        AutomaticDecompression = DecompressionMethods.All,
        ConnectTimeout = TimeSpan.FromSeconds(10)
    });

    internal static async Task<SubscriptionNodes> FetchAsync(Uri address)
    {
        var payload = await FetchTextAsync(address, "Shadowrocket/2.2.93", MaxBytes);
        return ParseNodes(payload.Text) with { Info = payload.Info };
    }

    internal static async Task<string> FetchClashAsync(Uri address) =>
        (await FetchTextAsync(address, "ClashforWindows/0.20.16", ClashYaml.MaxBytes)).Text;

    private static async Task<(string Text, SubscriptionInfo? Info)> FetchTextAsync(Uri address, string userAgent, int maxBytes)
    {
        using var expiry = new CancellationTokenSource(TimeSpan.FromSeconds(25));
        using var request = new HttpRequestMessage(HttpMethod.Get, address);
        request.Headers.UserAgent.ParseAdd(userAgent);
        try
        {
            using var response = await Download.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, expiry.Token);
            if (!response.IsSuccessStatusCode)
                throw new InvalidDataException($"订阅服务器返回 HTTP {(int)response.StatusCode}。");
            if (response.Content.Headers.ContentLength > maxBytes)
                throw new InvalidDataException($"订阅大小超过 {maxBytes / (1024 * 1024)} MB。");

            using var stream = await response.Content.ReadAsStreamAsync(expiry.Token);
            using var data = new MemoryStream();
            byte[] buffer = new byte[16384];
            int read;
            while ((read = await stream.ReadAsync(buffer, expiry.Token)) != 0)
            {
                if (data.Length + read > maxBytes)
                    throw new InvalidDataException($"订阅大小超过 {maxBytes / (1024 * 1024)} MB。");
                data.Write(buffer, 0, read);
            }
            return (Encoding.UTF8.GetString(data.GetBuffer(), 0, (int)data.Length),
                response.Headers.TryGetValues("subscription-userinfo", out var metadata) ? SubscriptionInfo.Parse(metadata) : null);
        }
        catch (OperationCanceledException) { throw new InvalidDataException("订阅下载超时，请重试。"); }
        catch (HttpRequestException) { throw new InvalidDataException("无法访问订阅服务器，请检查网络后重试。"); }
        catch (HttpIOException) { throw new InvalidDataException("订阅下载中断，请重试。"); }
    }

    internal static SubscriptionNodes ParseNodes(string content, int maxNodes = 512)
    {
        string text = content.Trim().TrimStart('\uFEFF');
        if (!text.Contains("://", StringComparison.Ordinal))
            text = Decode(text) ?? text;

        List<Node> nodes = [];
        int skipped = 0;
        foreach (string line in text.Split('\n'))
        {
            string link = line.Trim().TrimStart('\uFEFF');
            int separator = link.IndexOf("://", StringComparison.Ordinal);
            if (separator <= 0 || !Uri.CheckSchemeName(link[..separator]))
                continue;
            try
            {
                Node node = link[..separator].ToLowerInvariant() switch
                {
                    "vmess" => ParseVmess(link[(separator + 3)..]),
                    "vless" => ParseVless(link),
                    "ss" => ParseShadowsocks(link[(separator + 3)..]),
                    _ => throw new FormatException()
                };
                if (!nodes.Any(previous => NodeImport.SameNode(previous, node)))
                    nodes.Add(node);
            }
            catch (FormatException) { skipped++; }
            catch (JsonException) { skipped++; }

            if (nodes.Count > maxNodes)
                throw new InvalidDataException($"当前每个订阅支持最多 {maxNodes} 个节点。");
        }
        if (nodes.Count == 0)
            throw new InvalidDataException("订阅没有可导入的 VMess、VLESS 或 Shadowsocks 节点。");
        return new(nodes, skipped);
    }

    private static Node ParseVmess(string payload)
    {
        using var document = JsonDocument.Parse(Decode(payload) ?? throw new FormatException());
        var record = document.RootElement;
        string Text(string key) => NodeImport.Text(record, key);
        string host = Text("add");
        int port = Number(Text("port"));
        string cipher = Text("scy");
        var outbound = new JsonObject
        {
            ["uuid"] = Uuid(Text("id")),
            ["security"] = cipher.Length == 0 ? "auto" : cipher,
            ["alter_id"] = Text("aid").Length == 0 ? 0 : Number(Text("aid"))
        };

        string network = Text("net");
        AddTransport(outbound, network, Text("type"), Text("host"), Text("path"));
        string tls = Text("tls");
        if (tls == "tls")
            AddTls(outbound, First(Text("sni"), network == "ws" ? Text("host") : "", host), Text("alpn"), Text("fp"));
        else if (tls is not ("" or "none"))
            throw new FormatException();
        return MakeNode("vmess", Text("ps"), host, port, outbound);
    }

    private static Node ParseVless(string link)
    {
        if (!Uri.TryCreate(link, UriKind.Absolute, out var uri))
            throw new FormatException();
        var query = Query(uri.Query);
        string Value(string key) => query.GetValueOrDefault(key, "");
        if (Value("encryption") is not ("" or "none") || Value("allowInsecure") == "1")
            throw new FormatException();

        var outbound = new JsonObject { ["uuid"] = Uuid(Uri.UnescapeDataString(uri.UserInfo)) };
        string flow = Value("flow");
        if (flow.Length > 0)
        {
            if (flow != "xtls-rprx-vision")
                throw new FormatException();
            outbound["flow"] = flow;
        }

        AddTransport(outbound, Value("type"), Value("headerType"), Value("host"), Value("path"));
        string security = Value("security");
        if (security is "tls" or "reality")
        {
            string fingerprint = Value("fp");
            var tls = AddTls(outbound, First(Value("sni"), Value("type") == "ws" ? Value("host") : "", uri.IdnHost),
                Value("alpn"), fingerprint.Length == 0 && security == "reality" ? "chrome" : fingerprint);
            if (security == "reality")
                tls["reality"] = new JsonObject
                {
                    ["enabled"] = true,
                    ["public_key"] = Value("pbk") is { Length: > 0 } key ? key : throw new FormatException(),
                    ["short_id"] = Value("sid")
                };
        }
        else if (security is not ("" or "none"))
            throw new FormatException();

        return MakeNode("vless", Uri.UnescapeDataString(uri.Fragment.TrimStart('#')), uri.IdnHost, uri.Port, outbound);
    }

    private static Node ParseShadowsocks(string payload)
    {
        string[] pieces = payload.Split('#', 2);
        string[] fields = pieces[0].Split('?', 2);
        string authority = fields[0].TrimEnd('/');
        if (!authority.Contains('@'))
            authority = Decode(authority) ?? throw new FormatException();
        int at = authority.LastIndexOf('@');
        if (at <= 0 || !Uri.TryCreate("ss://" + authority[(at + 1)..], UriKind.Absolute, out var uri))
            throw new FormatException();

        string credentials = Uri.UnescapeDataString(authority[..at]);
        if (!credentials.Contains(':'))
            credentials = Decode(credentials) ?? throw new FormatException();
        string[] parts = credentials.Split(':', 2);
        if (parts.Length != 2 || parts[0].Length == 0 || parts[1].Length == 0)
            throw new FormatException();

        var outbound = new JsonObject { ["method"] = parts[0], ["password"] = parts[1] };
        if (fields.Length == 2 && Query(fields[1]).TryGetValue("plugin", out var plugin))
        {
            var options = plugin.Split(';', 2);
            if (options[0] is not ("obfs-local" or "v2ray-plugin"))
                throw new FormatException();
            outbound["plugin"] = options[0];
            if (options.Length == 2)
                outbound["plugin_opts"] = options[1];
        }
        return MakeNode("shadowsocks", pieces.Length == 2 ? Uri.UnescapeDataString(pieces[1]) : "",
            uri.IdnHost, uri.Port, outbound);
    }

    private static void AddTransport(JsonObject outbound, string network, string header, string host, string path)
    {
        if (header is not ("" or "none"))
            throw new FormatException();
        if (network is "" or "tcp" or "raw")
            return;
        if (network != "ws")
            throw new FormatException();
        var transport = new JsonObject { ["type"] = "ws", ["path"] = path.Length == 0 ? "/" : path };
        if (host.Length > 0)
            transport["headers"] = new JsonObject { ["Host"] = host };
        outbound["transport"] = transport;
    }

    private static JsonObject AddTls(JsonObject outbound, string host, string alpn, string fingerprint)
    {
        var tls = new JsonObject { ["enabled"] = true, ["server_name"] = host };
        if (alpn.Length > 0)
            tls["alpn"] = JsonSerializer.SerializeToNode(alpn.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries));
        if (fingerprint.Length > 0)
            tls["utls"] = new JsonObject { ["enabled"] = true, ["fingerprint"] = fingerprint };
        outbound["tls"] = tls;
        return tls;
    }

    private static Node MakeNode(string type, string name, string address, int port, JsonObject outbound)
    {
        string host = address.Trim().Trim('[', ']');
        if (Uri.CheckHostName(host) == UriHostNameType.Unknown || port is < 1 or > 65535)
            throw new FormatException();
        Guid id = Guid.NewGuid();
        outbound["type"] = type;
        outbound["tag"] = id.ToString();
        outbound["server"] = host;
        outbound["server_port"] = port;
        return new(id, SafeName(name, host), host, port, JsonSerializer.SerializeToElement(outbound));
    }

    private static int Number(string value) => int.TryParse(value, out var result) && result >= 0 ? result : throw new FormatException();
    private static string Uuid(string value) => Guid.TryParse(value, out var id) ? id.ToString() : throw new FormatException();
    private static string First(params string[] values) => values.FirstOrDefault(value => value.Length > 0) ?? throw new FormatException();

    internal static string SafeName(string name, string fallback)
    {
        string clean = new(name.Where(character => !char.IsControl(character)).Take(80).ToArray());
        return clean.Trim() is { Length: > 0 } result ? result : fallback;
    }

    private static Dictionary<string, string> Query(string query)
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (string pair in query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            string[] fields = pair.Split('=', 2);
            result.TryAdd(Uri.UnescapeDataString(fields[0]), fields.Length == 2 ? Uri.UnescapeDataString(fields[1]) : "");
        }
        return result;
    }

    internal static string? Decode(string text)
    {
        string normalized = new(Uri.UnescapeDataString(text).Where(c => !char.IsWhiteSpace(c)).ToArray());
        normalized = normalized.Replace('-', '+').Replace('_', '/');
        normalized = normalized.PadRight((normalized.Length + 3) / 4 * 4, '=');
        try { return Encoding.UTF8.GetString(Convert.FromBase64String(normalized)); }
        catch (FormatException) { return null; }
    }
}
