using System.ComponentModel;
using System.Globalization;

namespace Byway;

internal sealed class NodeRow(Node node) : INotifyPropertyChanged
{
    public Node Node { get; } = node;
    public string GroupNames => Groups.Count == 0 ? "未分组" : string.Join("、", Groups.Select(group => group.Name));
    public string Protocol => Node.ProtocolLabel;
    public string UseStatus { get; private set; } = "";
    public string Test { get; private set; } = "未测试";
    public string ExitDisplay { get; private set; } = "—";
    public string TestAge { get; private set; } = "—";
    public string? TestLocalTime => LastTestedAtUtc?.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture);
    internal IReadOnlyList<NodeGroup> Groups { get; private set; } = [];
    internal ProbeResult? Probe { get; private set; }
    internal DateTimeOffset? LastTestedAtUtc { get; private set; }
    public event PropertyChangedEventHandler? PropertyChanged;

    internal void UpdateGroups(IEnumerable<NodeGroup> groups)
    {
        Groups = groups.ToArray();
        PropertyChanged?.Invoke(this, new(nameof(GroupNames)));
    }

    internal void UpdateUseStatus(bool active, bool selected)
    {
        string status = active ? "使用中" : selected ? "已选为出口" : "";
        if (UseStatus == status)
            return;
        UseStatus = status;
        PropertyChanged?.Invoke(this, new(nameof(UseStatus)));
    }

    internal void Update(ProbeResult result) =>
        Update(result.Succeeded ? $"可用 · {result.Milliseconds} ms" : result.Error!, result.CompletedAtUtc, result);

    internal void Update(string test, DateTimeOffset? testedAtUtc = null) => Update(test, testedAtUtc, null);

    private void Update(string test, DateTimeOffset? testedAtUtc, ProbeResult? result)
    {
        Test = test;
        Probe = result;
        LastTestedAtUtc = testedAtUtc;
        ExitDisplay = result?.ExitIp is { } ip && result.ExitRegionName is { } region ? $"{region} · {ip}" : result?.ExitIp ?? "—";
        RefreshTestAge(DateTimeOffset.UtcNow);
        PropertyChanged?.Invoke(this, new(nameof(Test)));
        PropertyChanged?.Invoke(this, new(nameof(ExitDisplay)));
        PropertyChanged?.Invoke(this, new(nameof(TestLocalTime)));
    }

    internal void RefreshTestAge(DateTimeOffset now)
    {
        string label = LastTestedAtUtc is { } testedAt ? RelativeTime(now - testedAt) : "—";
        if (TestAge == label)
            return;
        TestAge = label;
        PropertyChanged?.Invoke(this, new(nameof(TestAge)));
    }

    private static string RelativeTime(TimeSpan age) => age.TotalMinutes switch
    {
        < 1 => "刚刚",
        < 60 => $"{(int)age.TotalMinutes} 分钟前",
        < 1440 => $"{(int)age.TotalHours} 小时前",
        _ => $"{(int)age.TotalDays} 天前"
    };
}
