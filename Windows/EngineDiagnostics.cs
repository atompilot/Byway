using System.Collections.Concurrent;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Byway;

internal sealed record EngineMessage(DateTimeOffset Time, string Text);
internal sealed record EngineConnection(Guid Id, string Source, string Target, string Network, string Rule,
    string Chain, string Exit, long Upload, long Download);

internal sealed partial class EngineDiagnostics
{
    private readonly ConcurrentQueue<EngineMessage> queue = new();

    internal EngineMessage[] Snapshot() => [.. queue.Reverse()];

    internal void Read(string? line, string[] secrets)
    {
        if (string.IsNullOrWhiteSpace(line))
            return;
        string message = Escape().Replace(line, "");
        foreach (string secret in secrets)
            message = message.Replace(secret, L10n.Text("[已隐藏]"), StringComparison.Ordinal);
        message = Address().Replace(message, L10n.Text("[地址已隐藏]"));
        queue.Enqueue(new(DateTimeOffset.Now, message.Length <= 500 ? message : message[..500]));
        while (queue.Count > 160)
            queue.TryDequeue(out _);
    }

    internal static string[] Redactions(string configuration)
    {
        using var document = JsonDocument.Parse(configuration);
        var values = new HashSet<string>(StringComparer.Ordinal);
        Visit(document.RootElement);
        return values.OrderByDescending(value => value.Length).ToArray();

        void Visit(JsonElement element)
        {
            if (element.ValueKind == JsonValueKind.Array)
                foreach (var child in element.EnumerateArray())
                    Visit(child);
            if (element.ValueKind != JsonValueKind.Object)
                return;
            foreach (var property in element.EnumerateObject())
            {
                var value = property.Value;
                if (property.Name.ToLowerInvariant() is "uuid" or "password" or "secret" or "authorization" or "token" &&
                    value.ValueKind == JsonValueKind.String && value.GetString() is { Length: > 0 } secret)
                    values.Add(secret);
                Visit(value);
            }
        }
    }

    [GeneratedRegex(@"\x1B\[[0-9;]*[A-Za-z]")]
    private static partial Regex Escape();
    [GeneratedRegex(@"[A-Za-z][A-Za-z0-9+.-]*://[^\s]+")]
    private static partial Regex Address();
}
