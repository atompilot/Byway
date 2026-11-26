using System.Security.Cryptography;
using System.Text.Json;

namespace Byway;

internal sealed record DesktopOptions(string Bypass = "", bool CloseToTray = true, int MixedPort = 7890,
    RoutingMode RouteMode = RoutingMode.Rule, bool StartAtLogin = false, bool ResumeProxy = false, bool ProxyWanted = false,
    CaptureMode Capture = CaptureMode.SystemProxy, double SidebarWidth = 180);
internal sealed record AiOptions(string Token, bool LanEnabled = false, bool DiscoveryEnabled = true)
{
    internal static string NewToken() => Convert.ToHexString(RandomNumberGenerator.GetBytes(32)).ToLowerInvariant();
}

internal sealed record SavedProfile(List<Node> Nodes, Guid? Selected, List<NodeGroup>? Groups = null,
    DesktopOptions? Options = null, AiOptions? Ai = null, List<ImportedRouting>? RoutingConfigurations = null,
    Guid? SelectedRouting = null, PrivateNetworkSettings? PrivateNetwork = null)
{
    private static readonly string Path = Program.StatePath("nodes.dat");

    internal static SavedProfile Load() => File.Exists(Path)
        ? JsonSerializer.Deserialize<SavedProfile>(
            ProtectedData.Unprotect(File.ReadAllBytes(Path), null, DataProtectionScope.CurrentUser))
          ?? throw new InvalidDataException(L10n.Text("无法读取已保存的节点。"))
        : new([], null);

    internal void Save() => Program.WriteAtomic(Path, ProtectedData.Protect(
        JsonSerializer.SerializeToUtf8Bytes(this), null, DataProtectionScope.CurrentUser));

    internal static void BackupBeforeClashMigration() => Backup("before-clash");
    internal static void BackupBeforeRuleAddition() => Backup("before-rule");

    private static void Backup(string purpose)
    {
        if (File.Exists(Path))
            File.Copy(Path, $"{Path}.{purpose}-{DateTime.UtcNow:yyyyMMdd-HHmmss-fffffff}");
    }

    internal ImportedRouting? ActiveRouting => RoutingConfigurations?.Find(item => item.Id == SelectedRouting);
}
