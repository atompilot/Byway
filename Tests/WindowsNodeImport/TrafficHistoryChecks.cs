using Byway;

internal static class TrafficHistoryChecks
{
    internal static void Run()
    {
        string root = Path.Combine(Path.GetTempPath(), $"byway-traffic-{Guid.NewGuid():N}");
        try
        {
            CheckRanges(Path.Combine(root, "ranges"));
            CheckDaylightSaving(Path.Combine(root, "daylight-saving"));
            CheckStorage(Path.Combine(root, "storage"));
        }
        finally
        {
            if (Directory.Exists(root))
                Directory.Delete(root, recursive: true);
        }
        Console.WriteLine("Traffic history totals, time ranges, daylight saving, data gaps, and persistence passed.");
    }

    private static void CheckRanges(string path)
    {
        var pacific = TimeZoneInfo.FindSystemTimeZoneById("America/Los_Angeles");
        var now = Utc(2026, 11, 25, 16);
        var history = new TrafficHistory(path, File.WriteAllBytes);
        var initial = history.Read(TrafficPeriod.Today, now, pacific);
        Require(initial.TotalBytes is null && initial.RecordedSinceUtc is null &&
            initial.Bins[0].State == "missing" && initial.Bins[^1].State == "future", "Empty history");

        history.Record(Utc(2026, 11, 25, 7, 59), 17, 3);
        history.Record(Utc(2026, 11, 25, 8), 10, 5);
        history.Record(Utc(2026, 11, 25, 8, 4), 4, 1);
        history.Record(Utc(2026, 11, 25, 9), 0, 0);

        var today = history.Read(TrafficPeriod.Today, now, pacific);
        Require(today.StartUtc == Utc(2026, 11, 25, 8) && today.Bins.Length == 24, "Local midnight");
        Require(today.TotalBytes == 20 && today.Bins[0].TotalBytes == 20 &&
            today.Bins[1].State == "recorded" && today.Bins[1].TotalBytes == 0 && today.Bins[2].TotalBytes is null,
            "Recorded zero, uncovered hour, and total");
        var yesterday = history.Read(TrafficPeriod.Yesterday, now, pacific);
        Require(yesterday.TotalBytes == 20 && yesterday.Bins[^1].TotalBytes == 20, "Previous day");
        var week = history.Read(TrafficPeriod.Last7Days, now, pacific);
        var month = history.Read(TrafficPeriod.Last30Days, now, pacific);
        Require(week.Granularity == "day" && week.Bins.Length == 7 && week.TotalBytes == 40 &&
            month.Bins.Length == 30 && month.TotalBytes == 40, "Recent ranges");
        var all = history.Read(TrafficPeriod.All, now, pacific);
        Require(all.TotalBytes == 40 && all.RecordedSinceUtc == Utc(2026, 11, 25, 7, 59), "All recorded data");

        history.Flush();
        history = new TrafficHistory(path, File.WriteAllBytes);
        history.Record(Utc(2026, 11, 25, 9, 10), 9, 2);
        history.Flush();
        history = new TrafficHistory(path, File.WriteAllBytes);
        Require(history.Read(TrafficPeriod.All, now, pacific).TotalBytes == 51, "Restart and append");

        var nepal = TimeZoneInfo.FindSystemTimeZoneById("Asia/Kathmandu");
        var quarterHour = history.Read(TrafficPeriod.Today, Utc(2026, 11, 25, 16), nepal);
        Require(quarterHour.StartUtc == Utc(2026, 11, 24, 18, 15) && quarterHour.TotalBytes == 51,
            "Quarter-hour time zone");
    }

    private static void CheckDaylightSaving(string path)
    {
        var pacific = TimeZoneInfo.FindSystemTimeZoneById("America/Los_Angeles");
        var history = new TrafficHistory(path, File.WriteAllBytes);
        var spring = history.Read(TrafficPeriod.Today, Utc(2026, 3, 8, 18), pacific);
        Require(spring.Bins.Length == 23, "Spring-forward day");

        history.Record(Utc(2026, 11, 1, 8, 4), 12, 2);
        history.Record(Utc(2026, 11, 1, 9, 4), 6, 3);
        var autumn = history.Read(TrafficPeriod.Today, Utc(2026, 11, 1, 18), pacific);
        Require(autumn.Bins.Length == 25 && autumn.Bins[1].TotalBytes == 14 && autumn.Bins[2].TotalBytes == 9 &&
            autumn.TotalBytes == 23, "Both repeated local hours");
    }

    private static void CheckStorage(string path)
    {
        var date = Utc(2026, 11, 25, 16);
        bool fail = true;
        var history = new TrafficHistory(path, (name, bytes) =>
        {
            if (fail)
                throw new IOException();
            File.WriteAllBytes(name, bytes);
        });
        history.Record(date.AddMinutes(-1), 19, 2);
        history.Flush();
        Require(history.Read(TrafficPeriod.All, date, TimeZoneInfo.Utc) is { TotalBytes: 21, StorageIssue: true }, "Failed save");
        fail = false;
        history.Flush();
        history = new TrafficHistory(path, File.WriteAllBytes);
        Require(history.Read(TrafficPeriod.All, date, TimeZoneInfo.Utc) is { TotalBytes: 21, StorageIssue: false }, "Retry dirty save");

        string file = Path.Combine(path, "2026-11-25.json");
        const string damaged = "[";
        File.WriteAllText(file, damaged);
        history = new TrafficHistory(path, File.WriteAllBytes);
        history.Record(date.AddSeconds(-1), 3, 1);
        history.Flush();
        Require(File.ReadAllText(file) == damaged &&
            history.Read(TrafficPeriod.All, date, TimeZoneInfo.Utc) is { TotalBytes: 4, StorageIssue: true },
            "Preserve unreadable history");
    }

    private static DateTimeOffset Utc(int year, int month, int day, int hour, int minute = 0) =>
        new(year, month, day, hour, minute, 0, TimeSpan.Zero);

    private static void Require(bool condition, string scenario)
    {
        if (!condition)
            throw new InvalidOperationException($"Traffic history regression: {scenario}.");
    }
}
