using System.Text.Json;
using System.Text.Json.Nodes;

namespace Byway;

internal sealed record Node(Guid Id, string Name, string Host, int Port, JsonElement Outbound)
{
    internal string ProtocolLabel
    {
        get
        {
            string type = NodeImport.Text(Outbound, "type");
            if (type == "vless" && Outbound.TryGetProperty("tls", out var tls) && tls.ValueKind == JsonValueKind.Object &&
                tls.TryGetProperty("reality", out var reality) && NodeImport.Text(reality, "enabled") == "true")
                return "VLESS · REALITY";

            return type switch
            {
                "vmess" => "VMess",
                "shadowsocks" => "Shadowsocks",
                "" => "—",
                _ => type.ToUpperInvariant()
            };
        }
    }

    internal Node WithId(Guid id)
    {
        var configuration = JsonNode.Parse(Outbound.GetRawText())!.AsObject();
        configuration["tag"] = id.ToString();
        return this with { Id = id, Outbound = JsonSerializer.SerializeToElement(configuration) };
    }
}

internal sealed record ImportEntry(string Name, Node? Node, string? Error);
internal sealed record ImportBatch(List<ImportEntry> Entries, int Subscriptions);

internal static class NodeImport
{
    internal static ImportBatch Read(string path)
    {
        using var stream = File.OpenRead(path);
        return Read(stream);
    }

    internal static ImportBatch Read(Stream stream)
    {
        if (stream.Length > 4 * 1024 * 1024)
            throw new InvalidDataException(L10n.Text("节点导出文件不能超过 4 MB。"));
        using var reader = new StreamReader(stream);
        using var document = JsonDocument.Parse(reader.ReadToEnd());
        if (document.RootElement.ValueKind != JsonValueKind.Array)
            throw new InvalidDataException(L10n.Text("请选择 Shadowrocket 导出的节点 JSON 文件。"));

        List<ImportEntry> entries = [];
        int subscriptions = 0;
        foreach (var entry in document.RootElement.EnumerateArray())
        {
            string name = Text(entry, "title").Trim();
            if (name.Length == 0)
                name = L10n.Format($"第 {entries.Count + subscriptions + 1} 条");
            name = new string(name.Where(c => !char.IsControl(c)).Take(80).ToArray());
            try
            {
                string type = Text(entry, "type");
                if (type.Equals("Subscribe", StringComparison.OrdinalIgnoreCase))
                {
                    subscriptions++;
                    continue;
                }
                if (!type.Equals("VLESS", StringComparison.OrdinalIgnoreCase))
                    throw new InvalidDataException(L10n.Text("当前支持 TCP / RAW VLESS 节点。"));
                entries.Add(new(name, ParseVless(entry, name), null));
            }
            catch (InvalidDataException error)
            {
                entries.Add(new(name, null, error.Message));
            }
        }
        return new(entries, subscriptions);
    }

    private static Node ParseVless(JsonElement entry, string name)
    {
        string host = Text(entry, "host").Trim().Trim('[', ']');
        if (Uri.CheckHostName(host) == UriHostNameType.Unknown ||
            !int.TryParse(Text(entry, "port"), out int port) || port is < 1 or > 65535)
            throw new InvalidDataException(L10n.Text("需要有效的主机和端口。"));
        // Shadowrocket's uuid identifies the export record. Its password is the VLESS user ID.
        if (!Guid.TryParse(Text(entry, "password"), out Guid uuid))
            throw new InvalidDataException(L10n.Text("需要有效的 VLESS UUID。"));
        if (!new[] { "", "none", "tcp", "raw" }.Contains(Text(entry, "obfs").ToLowerInvariant()) ||
            !new[] { "", "none" }.Contains(Text(entry, "plugin").ToLowerInvariant()) ||
            !new[] { "", "none" }.Contains(Text(entry, "proto").ToLowerInvariant()))
            throw new InvalidDataException(L10n.Text("此节点使用了暂未支持的传输选项。"));

        Guid id = Guid.NewGuid();
        var outbound = new JsonObject
        {
            ["type"] = "vless", ["tag"] = id.ToString(), ["server"] = host,
            ["server_port"] = port, ["uuid"] = uuid.ToString()
        };
        string flow = Text(entry, "flow");
        if (flow.Length != 0)
        {
            if (flow != "xtls-rprx-vision")
                throw new InvalidDataException(L10n.Text("此 VLESS 流控类型暂未支持。"));
            outbound["flow"] = flow;
        }

        string key = Text(entry, "publicKey");
        if (key.Length != 0 || Text(entry, "tls").Equals("true", StringComparison.OrdinalIgnoreCase))
        {
            string peer = Text(entry, "peer");
            var tls = new JsonObject { ["enabled"] = true, ["server_name"] = peer.Length == 0 ? host : peer };
            string[] alpn = Text(entry, "alpn").Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
            if (alpn.Length > 0)
                tls["alpn"] = JsonSerializer.SerializeToNode(alpn);
            string fingerprint = Text(entry, "tlsProfile").ToLowerInvariant();
            if (fingerprint.StartsWith("safari", StringComparison.Ordinal))
                fingerprint = "safari";
            if (fingerprint.Length == 0 && key.Length != 0)
                fingerprint = "chrome";
            if (fingerprint.Length != 0)
                tls["utls"] = new JsonObject { ["enabled"] = true, ["fingerprint"] = fingerprint };
            if (key.Length != 0)
                tls["reality"] = new JsonObject
                {
                    ["enabled"] = true, ["public_key"] = key, ["short_id"] = Text(entry, "shortId")
                };
            outbound["tls"] = tls;
        }
        return new(id, name, host, port, JsonSerializer.SerializeToElement(outbound));
    }

    internal static string Text(JsonElement entry, string key)
    {
        if (entry.ValueKind != JsonValueKind.Object || !entry.TryGetProperty(key, out var value))
            return "";
        return value.ValueKind switch
        {
            JsonValueKind.String => value.GetString() ?? "",
            JsonValueKind.Number or JsonValueKind.True or JsonValueKind.False => value.GetRawText(),
            _ => ""
        };
    }

    internal static bool SameNode(Node left, Node right) => left.Name == right.Name && SameEndpoint(left, right);

    internal static bool SameEndpoint(Node left, Node right) =>
        left.Host == right.Host && left.Port == right.Port && JsonElement.DeepEquals(left.WithId(right.Id).Outbound, right.Outbound);
}
