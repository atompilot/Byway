using System.ComponentModel;
using System.Diagnostics;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using YamlDotNet.RepresentationModel;

namespace Byway;

internal sealed record ClashWindowsMigration(string Name, string Text, string? SubscriptionUrl,
    Dictionary<string, string> Selections, string? GlobalTarget, string Bypass, int Port, RoutingMode Mode)
{
    internal string Revision() => Convert.ToHexString(SHA256.HashData(JsonSerializer.SerializeToUtf8Bytes(this)));

    internal static async Task<ClashWindowsMigration> ReadAsync(ProxySettings system)
    {
        string directory = FindDataDirectory();
        string profiles = Path.Combine(directory, "profiles");
        var index = ReadYaml(Path.Combine(profiles, "list.yml"));
        var entries = ClashYaml.Sequence(index.Get("files"), "files").ToArray();
        if (!int.TryParse(index.Text("index", ""), out int selected) || selected < 0 || selected >= entries.Length)
            throw new InvalidDataException(L10n.Text("请先在 Clash for Windows 中选择正在使用的配置。"));
        var entry = ClashYaml.Mapping(entries[selected], "files");
        string fileName = entry.Text("time");
        if (!Regex.IsMatch(fileName, @"\A[0-9]+\.ya?ml\z"))
            throw new InvalidDataException(L10n.Text("无法识别 Clash 当前配置的文件名。"));
        string text = ReadText(Path.Combine(profiles, fileName));
        var configuration = ClashConfiguration.Parse(text);
        string? url = entry.Get("url") is YamlScalarNode { Value: { Length: > 0 } source }
            ? SubscriptionLink.Parse(source).Address.AbsoluteUri : null;

        var settings = ReadYaml(Path.Combine(directory, "config.yaml"));
        if (!IPEndPoint.TryParse(settings.Text("external-controller", ""), out var controller) ||
            !IPAddress.IsLoopback(controller.Address) || controller.Port == 0)
            throw new InvalidDataException(L10n.Text("无法读取正在运行的 Clash 本机控制接口。"));
        using var http = new HttpClient(new SocketsHttpHandler { UseProxy = false, AllowAutoRedirect = false })
        {
            BaseAddress = new Uri($"http://{controller}/"), Timeout = TimeSpan.FromSeconds(3),
            MaxResponseContentBufferSize = ClashYaml.MaxBytes
        };
        string? secret = (settings.Get("secret") as YamlScalarNode)?.Value;
        if (!string.IsNullOrEmpty(secret))
            http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", secret);

        try
        {
            using var live = JsonDocument.Parse(await http.GetStringAsync("configs"));
            var data = live.RootElement;
            if (!data.TryGetProperty("mixed-port", out var mixed) || !mixed.TryGetInt32(out int port) ||
                port is < 1 or > 65535 or 8766 or 8767 || !UsesSystemProxy(system, port))
                throw new InvalidDataException(L10n.Text("请先在 Clash 中开启系统代理，再读取当前端口和代理例外。"));
            var mode = StringField(data, "mode") switch
            {
                "rule" => RoutingMode.Rule,
                "global" => RoutingMode.Global,
                "direct" => RoutingMode.Direct,
                _ => throw new InvalidDataException(L10n.Text("Clash 当前的运行模式暂不支持迁移。"))
            };

            using var current = JsonDocument.Parse(await http.GetStringAsync("proxies"));
            var proxies = current.RootElement.GetProperty("proxies");
            var choices = new Dictionary<string, string>(StringComparer.Ordinal);
            foreach (var group in configuration.Groups)
            {
                var member = proxies.TryGetProperty(group.Name, out var runtimeGroup) ? StringField(runtimeGroup, "now") : null;
                if (member is null || !group.Members.Contains(member))
                    throw new InvalidDataException(L10n.Text("Clash 正在运行的策略组与保存的配置不同。请在 Clash 中重新选中当前配置后重试。"));
                choices.Add(group.Name, member);
            }
            var target = proxies.TryGetProperty("GLOBAL", out var global) ? StringField(global, "now") : null;
            if (!configuration.GlobalTargets.Contains(target))
                target = null;
            if (mode == RoutingMode.Global && target is null)
                throw new InvalidDataException(L10n.Text("Clash 的全局出口无法迁移。请先选择当前配置中的全局出口。"));

            return new(entry.Text("name", "Clash"), text, url, choices, target, system.Bypass, port, mode);
        }
        catch (Exception error) when (error is HttpRequestException or OperationCanceledException or JsonException or KeyNotFoundException)
        {
            throw new InvalidDataException(L10n.Text("无法读取 Clash 的运行状态。请确认 Clash for Windows 正在运行后再试。"));
        }
    }

    private static bool UsesSystemProxy(ProxySettings system, int port) => (system.Flags & 2) != 0 &&
        string.IsNullOrEmpty(system.PacUrl) && Uri.TryCreate($"http://{system.Server}", UriKind.Absolute, out var endpoint) &&
        endpoint.IsLoopback && endpoint.Port == port;

    private static string FindDataDirectory()
    {
        var roots = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        using var current = Process.GetCurrentProcess();
        foreach (var process in Process.GetProcessesByName("Clash for Windows"))
        {
            using (process)
            {
                try
                {
                    if (process.SessionId == current.SessionId &&
                        Path.GetDirectoryName(process.MainModule?.FileName) is { } app)
                        roots.Add(Path.Combine(app, "data"));
                }
                catch (Exception error) when (error is InvalidOperationException or Win32Exception) { }
            }
        }
        if (roots.Count != 1)
            throw new InvalidDataException(L10n.Text("请先在当前 Windows 会话中打开一份 Clash for Windows。"));
        var portable = roots.Single();
        string standard = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".config", "clash");
        return File.Exists(Path.Combine(portable, "profiles", "list.yml")) ? portable : standard;
    }

    private static YamlMappingNode ReadYaml(string path) => ClashYaml.Read(ReadText(path));

    private static string ReadText(string path)
    {
        if (!File.Exists(path))
            throw new InvalidDataException(L10n.Text("找不到 Clash for Windows 的在用配置。可从配置页导入 Clash YAML。"));
        using var file = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        if (file.Length > ClashYaml.MaxBytes)
            throw new InvalidDataException(L10n.Text("Clash 文件超过可迁移的 2 MB。"));
        byte[] data = new byte[file.Length];
        file.ReadExactly(data);
        return Encoding.UTF8.GetString(data).TrimStart('\uFEFF');
    }

    private static string? StringField(JsonElement element, string key) =>
        element.ValueKind == JsonValueKind.Object && element.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString() : null;
}
