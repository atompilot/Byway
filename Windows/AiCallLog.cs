namespace Byway;

internal sealed record AiCall(DateTimeOffset Time, string Source, string Method, string Path, int Status, long Milliseconds);

internal sealed class AiCallLog
{
    internal const int Limit = 200;
    private readonly Queue<AiCall> recent = new(Limit);
    private static readonly HashSet<string> RouteWords =
    [
        "v1", "guide", "skill", "status", "nodes", "groups", "config", "settings", "statistics",
        "ai", "proxy", "share", "probe", "select", "refresh", "rotate-token", "import", "qr", "decode",
        "camera", "shadowrocket", "preview", "active"
    ];

    internal void Record(DateTimeOffset time, string source, string method, string? path, int status, long milliseconds)
    {
        string displayMethod = method is "GET" or "POST" or "PUT" or "PATCH" or "DELETE" ? method : L10n.Text("其他");
        string displayPath = DisplayPath(path);
        lock (recent)
        {
            if (recent.Count == Limit)
                recent.Dequeue();
            recent.Enqueue(new(time, source, displayMethod, displayPath, status, milliseconds));
        }
    }

    internal AiCall[] Snapshot()
    {
        lock (recent)
            return recent.Reverse().ToArray();
    }

    private static string DisplayPath(string? path)
    {
        if (path is null)
            return "—";
        string[] segments = path.Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (segments.Length is < 2 or > 4 || segments[0] != "v1")
            return L10n.Text("未知路径");
        for (int i = 1; i < segments.Length; i++)
        {
            if (RouteWords.Contains(segments[i]))
                continue;
            bool isResource = i == 2 && segments[1] is "nodes" or "groups" ||
                i == 3 && segments[1] == "config" && segments[2] == "shadowrocket";
            if (!isResource || !Guid.TryParse(segments[i], out Guid id))
                return L10n.Text("未知路径");
            segments[i] = id.ToString();
        }
        return "/" + string.Join('/', segments);
    }
}
