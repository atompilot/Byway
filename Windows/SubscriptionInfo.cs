using System.Globalization;

namespace Byway;

internal sealed record SubscriptionInfo(long? UploadBytes, long? DownloadBytes, long? TotalBytes, DateTimeOffset? ExpiresAt)
{
    internal long? RemainingBytes => TotalBytes is > 0 && UploadBytes is long upload && DownloadBytes is long download
        ? (long)Math.Max(0m, (decimal)TotalBytes.Value - upload - download)
        : null;

    internal static SubscriptionInfo? Parse(IEnumerable<string> values)
    {
        var fields = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
        foreach (string value in values)
        {
            foreach (string field in value.Split(';', StringSplitOptions.RemoveEmptyEntries))
            {
                int separator = field.IndexOf('=');
                if (separator > 0 && long.TryParse(field.AsSpan(separator + 1).Trim(), NumberStyles.None, CultureInfo.InvariantCulture, out long number))
                    fields.TryAdd(field[..separator].Trim(), number);
            }
        }

        long? Read(string name) => fields.TryGetValue(name, out long value) ? value : null;
        long? upload = Read("upload");
        long? download = Read("download");
        long? total = Read("total");
        long? timestamp = Read("expire");
        DateTimeOffset? expires = timestamp is > 0 && timestamp <= DateTimeOffset.MaxValue.ToUnixTimeSeconds()
            ? DateTimeOffset.FromUnixTimeSeconds(timestamp.Value) : null;
        return upload is null && download is null && total is not > 0 && expires is null
            ? null : new(upload, download, total, expires);
    }
}
