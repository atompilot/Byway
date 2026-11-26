using System.Globalization;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Byway;

internal abstract record ImportCode
{
    internal sealed record SubscriptionCode(SubscriptionLink Link) : ImportCode;
    internal sealed record NodeCode(Node Node) : ImportCode;
    internal sealed record GroupCode(string Name, List<Node> Nodes) : ImportCode;

    internal static ImportCode Parse(string value)
    {
        string text = value.Trim();
        if (text.StartsWith("sub://", StringComparison.OrdinalIgnoreCase) ||
            text.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
            return new SubscriptionCode(SubscriptionLink.Parse(text));
        if (text.StartsWith(ShareCodes.GroupPrefix, StringComparison.OrdinalIgnoreCase))
            return ShareCodes.ReadGroup(text);
        if (text.StartsWith("vless://", StringComparison.OrdinalIgnoreCase) ||
            text.StartsWith("vmess://", StringComparison.OrdinalIgnoreCase) ||
            text.StartsWith("ss://", StringComparison.OrdinalIgnoreCase))
        {
            if (text.Contains('\n') || text.Contains('\r'))
                throw new InvalidDataException(L10n.Text("请一次导入一个节点链接或一份节点组分享码。"));
            return new NodeCode(Subscription.ParseNodes(text).Nodes.Single());
        }
        throw new InvalidDataException(L10n.Text("请扫描 Byway 节点组、订阅或受支持的节点二维码。"));
    }
}

internal static class ShareCodes
{
    internal const string GroupPrefix = "byway-group://";
    internal const int MaxCodeLength = 2 * 1024 * 1024;
    private const int MaxGroupJson = 4 * 1024 * 1024;

    internal static string ForSubscription(NodeGroup group) =>
        "sub://" + Base64Url(Encoding.UTF8.GetBytes(group.SubscriptionAddress!)) + "#" + Uri.EscapeDataString(group.Name);

    internal static string ForNode(Node node)
    {
        var outbound = node.Outbound;
        var tls = Property(outbound, "tls");
        var realism = Property(tls, "reality");
        var transport = Property(outbound, "transport");
        string security = realism.ValueKind == JsonValueKind.Object ? "reality" : Text(tls, "enabled") == "true" ? "tls" : "";
        string fingerprint = Text(Property(tls, "utls"), "fingerprint");
        string serverName = Text(tls, "server_name");
        var values = Property(tls, "alpn");
        string alpn = values.ValueKind == JsonValueKind.Array ? string.Join(',', values.EnumerateArray().Select(item => item.GetString())) : "";
        string net = Text(transport, "type") is { Length: > 0 } network ? network : "tcp";
        string host = Text(Property(transport, "headers"), "Host");
        string path = Text(transport, "path");
        string authority = (node.Host.Contains(':') ? $"[{node.Host}]" : node.Host) + ":" + node.Port.ToString(CultureInfo.InvariantCulture);
        string label = "#" + Uri.EscapeDataString(node.Name);

        return Text(outbound, "type") switch
        {
            "vless" => $"vless://{Text(outbound, "uuid")}@{authority}?" +
                Query(("encryption", "none"), ("type", net), ("security", security), ("sni", serverName),
                    ("host", host), ("path", path), ("alpn", alpn), ("fp", fingerprint), ("flow", Text(outbound, "flow")),
                    ("pbk", Text(realism, "public_key")), ("sid", Text(realism, "short_id"))) + label,
            "vmess" => "vmess://" + Convert.ToBase64String(JsonSerializer.SerializeToUtf8Bytes(new
            {
                v = "2", ps = node.Name, add = node.Host, port = node.Port.ToString(CultureInfo.InvariantCulture),
                id = Text(outbound, "uuid"), aid = Text(outbound, "alter_id"), scy = Text(outbound, "security"),
                net, type = "none", host, path, tls = security, sni = serverName, alpn, fp = fingerprint
            })),
            "shadowsocks" => Shadowsocks(outbound, authority) + label,
            _ => throw new InvalidDataException(L10n.Text("此节点格式暂无法生成分享链接。"))
        };
    }

    private static string Shadowsocks(JsonElement outbound, string authority)
    {
        string method = Text(outbound, "method");
        string password = Text(outbound, "password");
        string userInfo = method.StartsWith("2022-", StringComparison.Ordinal)
            ? Uri.EscapeDataString(method) + ":" + Uri.EscapeDataString(password)
            : Base64Url(Encoding.UTF8.GetBytes($"{method}:{password}"));
        string plugin = Text(outbound, "plugin");
        string options = Text(outbound, "plugin_opts");
        return $"ss://{userInfo}@{authority}" + (plugin.Length == 0 ? "" :
            "/?" + Query(("plugin", plugin + (options.Length > 0 ? ";" + options : ""))));
    }

    internal static string ForGroup(string name, IReadOnlyList<Node> nodes)
    {
        if (nodes.Count == 0)
            throw new InvalidDataException(L10n.Text("节点组为空。"));
        var json = JsonSerializer.SerializeToUtf8Bytes(new GroupPayload(name, nodes.Select(ForNode).ToArray()));
        if (json.Length > MaxGroupJson)
            throw new InvalidDataException(L10n.Text("该节点组的分享内容超过 4 MB。"));
        using var output = new MemoryStream();
        using (var zip = new GZipStream(output, CompressionLevel.Optimal, leaveOpen: true))
            zip.Write(json);
        string value = GroupPrefix + Base64Url(output.ToArray());
        if (value.Length > MaxCodeLength)
            throw new InvalidDataException(L10n.Text("该节点组过大，无法生成分享二维码。"));
        return value;
    }

    internal static ImportCode.GroupCode ReadGroup(string value)
    {
        if (value.Length > MaxCodeLength)
            throw new InvalidDataException(L10n.Text("分享内容过大。"));
        try
        {
            string encoded = value[GroupPrefix.Length..].Replace('-', '+').Replace('_', '/');
            using var compressed = new MemoryStream(Convert.FromBase64String(encoded.PadRight((encoded.Length + 3) / 4 * 4, '=')));
            using var zip = new GZipStream(compressed, CompressionMode.Decompress);
            using var json = new MemoryStream();
            var buffer = new byte[16384];
            int read;
            while ((read = zip.Read(buffer)) != 0)
            {
                if (json.Length + read > MaxGroupJson)
                    throw new InvalidDataException(L10n.Text("分享内容超过 4 MB。"));
                json.Write(buffer, 0, read);
            }
            var group = JsonSerializer.Deserialize<GroupPayload>(json.ToArray());
            if (group?.Links is not { Length: > 0 } links || links.Any(link => string.IsNullOrWhiteSpace(link) || link.Contains('\n') || link.Contains('\r')))
                throw new FormatException();

            var parsed = Subscription.ParseNodes(string.Join('\n', links), links.Length);
            if (parsed.Skipped != 0)
                throw new InvalidDataException(L10n.Text("节点组含有无效或不支持的节点。"));
            return new(Subscription.SafeName(group.Name ?? "", L10n.Text("分享的节点组")), parsed.Nodes);
        }
        catch (Exception error) when (error is FormatException or JsonException)
        {
            throw new InvalidDataException(L10n.Text("节点组分享码无法读取。"));
        }
    }

    private static string Query(params (string Key, string Value)[] pairs) =>
        string.Join('&', pairs.Where(pair => pair.Value.Length > 0)
            .Select(pair => pair.Key + "=" + Uri.EscapeDataString(pair.Value)));

    private static string Text(JsonElement element, string key) => NodeImport.Text(element, key);
    private static JsonElement Property(JsonElement element, string key) =>
        element.ValueKind == JsonValueKind.Object && element.TryGetProperty(key, out var value) ? value : default;
    private static string Base64Url(byte[] bytes) => Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
    private sealed record GroupPayload(string Name, string[] Links);
}

internal sealed class QrParts
{
    private const string Prefix = "byway-part://";
    private const int ChunkSize = 1450;
    private string? checksum;
    private string?[] parts = [];

    internal static string[] Split(string value)
    {
        ArgumentOutOfRangeException.ThrowIfGreaterThan(value.Length, ShareCodes.MaxCodeLength);
        if (value.Length <= ChunkSize)
            return [value];
        string hash = Checksum(value);
        int count = (value.Length + ChunkSize - 1) / ChunkSize;
        return Enumerable.Range(0, count).Select(index =>
        {
            int start = index * ChunkSize;
            return $"{Prefix}{hash}/{index + 1}/{count}/{value.Substring(start, Math.Min(ChunkSize, value.Length - start))}";
        }).ToArray();
    }

    internal string? Accept(string code, out string? progress)
    {
        progress = null;
        if (!code.StartsWith(Prefix, StringComparison.OrdinalIgnoreCase))
            return code;
        string[] fields = code[Prefix.Length..].Split('/', 4);
        if (fields.Length != 4 || fields[0].Length != 16 || !fields[0].All(Uri.IsHexDigit) ||
            !int.TryParse(fields[1], NumberStyles.None, CultureInfo.InvariantCulture, out int part) ||
            !int.TryParse(fields[2], NumberStyles.None, CultureInfo.InvariantCulture, out int total) ||
            total < 2 || total > (ShareCodes.MaxCodeLength + ChunkSize - 1) / ChunkSize ||
            part < 1 || part > total || fields[3].Length is < 1 or > ChunkSize)
            throw new InvalidDataException(L10n.Text("这张分段二维码无法读取。"));
        if (checksum != fields[0] || parts.Length != total)
        {
            checksum = fields[0];
            parts = new string?[total];
        }
        parts[part - 1] = fields[3];
        int received = parts.Count(value => value is not null);
        if (received < total)
        {
            progress = L10n.Format($"已读取 {received} / {total} 张，请继续扫描同组二维码。");
            return null;
        }
        string result = string.Concat(parts);
        if (!string.Equals(Checksum(result), checksum, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException(L10n.Text("二维码内容校验失败，请重新扫描整组。"));
        return result;
    }

    private static string Checksum(string value) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value)))[..16];
}
