using System.Globalization;
using System.Text.Json;

namespace Byway;

internal enum TrafficPeriod { Today, Yesterday, Last7Days, Last30Days, All }

internal sealed record TrafficHistoryBin(DateTimeOffset StartUtc, DateTimeOffset EndUtc, string State,
    long? DownloadBytes = null, long? UploadBytes = null)
{
    public long? TotalBytes => DownloadBytes + UploadBytes;
}

internal sealed record TrafficHistorySnapshot(string Period, string Granularity, string TimeZone,
    DateTimeOffset StartUtc, DateTimeOffset EndUtc, DateTimeOffset AsOfUtc, DateTimeOffset? RecordedSinceUtc,
    long? DownloadBytes, long? UploadBytes, bool StorageIssue, TrafficHistoryBin[] Bins)
{
    public long? TotalBytes => DownloadBytes + UploadBytes;
}

internal sealed class TrafficHistory
{
    // UTC slots stay stable through daylight saving changes and align with Windows' quarter-hour time zones.
    private static readonly TimeSpan SlotDuration = TimeSpan.FromMinutes(15);
    private const string DatePattern = "yyyy-MM-dd";
    private readonly string directory;
    private readonly Action<string, byte[]> write;
    private readonly SortedDictionary<DateOnly, SortedDictionary<DateTimeOffset, Slot>> days = [];
    private readonly HashSet<DateOnly> unreadable = [];
    private readonly HashSet<DateOnly> dirty = [];
    private bool directoryReadFailed;
    private bool saveFailed;
    private DateTimeOffset? recordedSince;

    internal TrafficHistory(string directory, Action<string, byte[]> write)
    {
        this.directory = directory;
        this.write = write;
        try
        {
            if (!Directory.Exists(directory))
                return;
            foreach (string path in Directory.EnumerateFiles(directory, "*.json"))
                if (DateOnly.TryParseExact(Path.GetFileNameWithoutExtension(path), DatePattern,
                        CultureInfo.InvariantCulture, DateTimeStyles.None, out var day))
                    LoadDay(day, path);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            directoryReadFailed = true;
        }
    }

    internal void Record(DateTimeOffset sampleTime, long downloaded, long uploaded)
    {
        var at = sampleTime.ToUniversalTime();
        var day = DateOnly.FromDateTime(at.UtcDateTime);
        if (!days.TryGetValue(day, out var slots))
        {
            string path = DayPath(day);
            if (!unreadable.Contains(day) && File.Exists(path))
                LoadDay(day, path);
            if (!days.TryGetValue(day, out slots))
                days.Add(day, slots = []);
        }

        var start = SlotStart(at);
        var before = slots.GetValueOrDefault(start);
        slots[start] = new(start, before is not null && before.FirstObservedUtc < at ? before.FirstObservedUtc : at,
            (before?.DownloadBytes ?? 0) + downloaded, (before?.UploadBytes ?? 0) + uploaded);
        if (recordedSince is null || at < recordedSince)
            recordedSince = at;
        if (before is null || before.FirstObservedUtc > at || downloaded != 0 || uploaded != 0)
            dirty.Add(day);
    }

    internal void Flush()
    {
        if (dirty.Count == 0)
            return;
        saveFailed = false;
        try
        {
            Directory.CreateDirectory(directory);
            foreach (var day in dirty.ToArray())
            {
                if (unreadable.Contains(day))
                    continue;
                try
                {
                    write(DayPath(day), JsonSerializer.SerializeToUtf8Bytes(days[day].Values.ToArray()));
                    dirty.Remove(day);
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException)
                {
                    saveFailed = true;
                }
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            saveFailed = true;
        }
    }

    internal TrafficHistorySnapshot Read(TrafficPeriod period, DateTimeOffset time, TimeZoneInfo zone)
    {
        var now = time.ToUniversalTime();
        var today = DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(now, zone).DateTime);
        var firstDay = recordedSince is { } started && started <= now
            ? DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(started, zone).DateTime) : today;
        var from = period switch
        {
            TrafficPeriod.Yesterday => today.AddDays(-1),
            TrafficPeriod.Last7Days => today.AddDays(-6),
            TrafficPeriod.Last30Days => today.AddDays(-29),
            TrafficPeriod.All => firstDay,
            _ => today
        };
        var until = period == TrafficPeriod.Yesterday ? today : today.AddDays(1);
        var start = Midnight(from, zone);
        var end = Midnight(until, zone);
        var granularity = period switch
        {
            TrafficPeriod.Today or TrafficPeriod.Yesterday => "hour",
            TrafficPeriod.All => (until.Year - from.Year) * 12 + until.Month - from.Month >= 24 ? "year" : "month",
            _ => "day"
        };

        var intervals = Intervals(start, end, from, until, granularity, zone);
        var observed = ObservedSlots(start, end, now);
        using var slots = observed.GetEnumerator();
        bool hasSlot = slots.MoveNext();
        var bins = new TrafficHistoryBin[intervals.Count];
        long? download = null;
        long? upload = null;
        for (int i = 0; i < intervals.Count; i++)
        {
            var (left, right) = intervals[i];
            long? down = null;
            long? up = null;
            while (hasSlot && slots.Current.StartUtc < right)
            {
                var item = slots.Current;
                down = (down ?? 0) + item.DownloadBytes;
                up = (up ?? 0) + item.UploadBytes;
                hasSlot = slots.MoveNext();
            }
            if (down is not null)
            {
                download = (download ?? 0) + down.Value;
                upload = (upload ?? 0) + up!.Value;
            }
            string state = down is not null ? "recorded" : left > now ? "future" : "missing";
            bins[i] = new(left, right, state, down, up);
        }

        return new(PeriodCode(period), granularity, zone.Id, start, end, now, recordedSince, download, upload,
            saveFailed || directoryReadFailed || unreadable.Count > 0, bins);
    }

    internal static string PeriodCode(TrafficPeriod period) => period switch
    {
        TrafficPeriod.Today => "today",
        TrafficPeriod.Yesterday => "yesterday",
        TrafficPeriod.Last7Days => "last7days",
        TrafficPeriod.Last30Days => "last30days",
        TrafficPeriod.All => "all",
        _ => throw new ArgumentOutOfRangeException(nameof(period))
    };

    private IEnumerable<Slot> ObservedSlots(DateTimeOffset start, DateTimeOffset end, DateTimeOffset asOf)
    {
        var first = DateOnly.FromDateTime(start.UtcDateTime);
        var last = DateOnly.FromDateTime(end.UtcDateTime);
        foreach (var (day, slots) in days)
        {
            if (day < first)
                continue;
            if (day > last)
                yield break;
            foreach (var slot in slots.Values)
                if (slot.StartUtc >= start && slot.StartUtc < end && slot.FirstObservedUtc <= asOf)
                    yield return slot;
        }
    }

    private static List<(DateTimeOffset Start, DateTimeOffset End)> Intervals(DateTimeOffset start, DateTimeOffset end,
        DateOnly from, DateOnly until, string granularity, TimeZoneInfo zone)
    {
        var intervals = new List<(DateTimeOffset, DateTimeOffset)>();
        if (granularity == "hour")
        {
            for (var left = start; left < end;)
            {
                var next = left.AddHours(1);
                var right = next < end ? next : end;
                intervals.Add((left, right));
                left = right;
            }
            return intervals;
        }

        for (var day = from; day < until;)
        {
            var next = granularity switch
            {
                "month" => new DateOnly(day.Year, day.Month, 1).AddMonths(1),
                "year" => new DateOnly(day.Year + 1, 1, 1),
                _ => day.AddDays(1)
            };
            if (next > until)
                next = until;
            var left = Midnight(day, zone);
            var right = Midnight(next, zone);
            if (left < right)
                intervals.Add((left, right));
            day = next;
        }
        return intervals;
    }

    private static DateTimeOffset Midnight(DateOnly day, TimeZoneInfo zone)
    {
        var wall = day.ToDateTime(TimeOnly.MinValue);
        while (zone.IsInvalidTime(wall))
            wall = wall.AddMinutes(1);
        var offset = zone.IsAmbiguousTime(wall) ? zone.GetAmbiguousTimeOffsets(wall).Max() : zone.GetUtcOffset(wall);
        return new DateTimeOffset(wall, offset).ToUniversalTime();
    }

    private void LoadDay(DateOnly day, string path)
    {
        try
        {
            var slots = JsonSerializer.Deserialize<Slot[]>(File.ReadAllBytes(path)) ?? throw new InvalidDataException();
            var values = new SortedDictionary<DateTimeOffset, Slot>();
            foreach (var slot in slots)
            {
                if (slot is null || slot.StartUtc != SlotStart(slot.FirstObservedUtc) ||
                    DateOnly.FromDateTime(slot.StartUtc.UtcDateTime) != day || slot.DownloadBytes < 0 || slot.UploadBytes < 0 ||
                    !values.TryAdd(slot.StartUtc, slot))
                    throw new InvalidDataException();
            }
            days.Add(day, values);
            foreach (var slot in values.Values)
                if (recordedSince is null || slot.FirstObservedUtc < recordedSince)
                    recordedSince = slot.FirstObservedUtc;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or InvalidDataException)
        {
            unreadable.Add(day);
        }
    }

    private string DayPath(DateOnly day) => Path.Combine(directory, day.ToString(DatePattern, CultureInfo.InvariantCulture) + ".json");

    private static DateTimeOffset SlotStart(DateTimeOffset time)
    {
        long ticks = time.UtcTicks;
        return new(ticks - ticks % SlotDuration.Ticks, TimeSpan.Zero);
    }

    private sealed record Slot(DateTimeOffset StartUtc, DateTimeOffset FirstObservedUtc, long DownloadBytes, long UploadBytes);
}
