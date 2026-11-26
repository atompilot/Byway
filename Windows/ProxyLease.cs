using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Text.Json;

namespace Byway;

internal sealed record ProcessIdentity(int Pid, long Started)
{
    internal static ProcessIdentity Current() => new(Environment.ProcessId, Process.GetCurrentProcess().StartTime.ToFileTimeUtc());

    internal bool IsAlive()
    {
        try
        {
            using var process = Process.GetProcessById(Pid);
            return !process.HasExited && process.StartTime.ToFileTimeUtc() == Started;
        }
        catch (ArgumentException) { return false; }
        catch (InvalidOperationException) { return false; }
    }
}

internal sealed record Lease(
    ProxySettings Original, string Endpoint, string? PreviousEndpoint,
    ProcessIdentity Guard, ProcessIdentity Owner, ProcessIdentity Core,
    ProxySettings? Managed = null, ProxySettings? PreviousManaged = null)
{
    internal bool Owns(ProxySettings value) =>
        Managed is not null ? Managed.MatchesActiveSettings(value) || PreviousManaged?.MatchesActiveSettings(value) == true :
        (value.Flags & 2) != 0 && (value.Server == Endpoint || value.Server == PreviousEndpoint);
}

internal static class ProxyLease
{
    private static readonly string Path = Program.StatePath("proxy-recovery.json");

    internal static void RecoverAtLaunch() => Locked(() =>
    {
        if (Read() is { } lease)
            Restore(lease);
    });

    internal static bool IsActive(Core core, string endpoint, string bypass) => Locked(() =>
        Read() is { } lease && lease.Core.Pid == core.Pid &&
        ProxySettings.ForByway(endpoint, bypass, core.Capture).MatchesActiveSettings(WinProxy.Read()));

    internal static void Activate(Core core, ProcessIdentity guard, string endpoint, string bypass, Action commit) => Locked(() =>
    {
        if (!guard.IsAlive() || !core.Running)
            throw new InvalidOperationException(L10n.Text("代理内核或恢复进程已停止。"));

        Lease? previous = Read();
        ProxySettings before = WinProxy.Read();
        if (previous is not null && !previous.Owns(before))
        {
            File.Delete(Path);
            previous = null;
        }

        var managed = ProxySettings.ForByway(endpoint, bypass, core.Capture);
        var next = new Lease(previous?.Original ?? before, endpoint, previous?.Endpoint,
            guard, ProcessIdentity.Current(), new(core.Pid, core.StartTime), managed, previous is null ? null : before);
        Save(next); // Persist the original and both managed endpoints before changing Windows settings.
        try
        {
            WinProxy.Write(managed);
            Save(next with { PreviousEndpoint = null, PreviousManaged = null });
            commit();
        }
        catch
        {
            if (next.Owns(WinProxy.Read()))
                WinProxy.Write(before);
            if (previous is null)
                File.Delete(Path);
            else
                Save(previous);
            throw;
        }
    });

    internal static void UpdateBypass(Core core, string endpoint, string previous, string next, Action commit) => Locked(() =>
    {
        var before = ProxySettings.ForByway(endpoint, previous);
        if (Read() is not { } lease || lease.Core.Pid != core.Pid || !core.Running || WinProxy.Read() != before)
            throw new InvalidOperationException(L10n.Text("系统代理已变化，请重新开启 Byway 代理后再保存。"));

        var updated = lease with { Managed = ProxySettings.ForByway(endpoint, next), PreviousManaged = before };
        Save(updated);
        try
        {
            WinProxy.Write(updated.Managed!);
            Save(updated with { PreviousManaged = null });
            commit();
        }
        catch
        {
            if (updated.Owns(WinProxy.Read()))
                WinProxy.Write(before);
            Save(lease);
            throw;
        }
    });

    internal static void Release() => Locked(() =>
    {
        if (Read() is { } lease)
            Restore(lease);
    });

    internal static void ReleaseForManual(string listener, Action commit) => Locked(() =>
    {
        if (Read() is not { } lease)
        {
            commit();
            return;
        }

        var before = WinProxy.Read();
        if (!lease.Owns(before))
        {
            File.Delete(Path);
            commit();
            return;
        }

        var restored = RestoreAvailableProxy(lease, listener);
        try
        {
            if (restored != before)
                WinProxy.Write(restored);
            File.Delete(Path);
            commit();
        }
        catch
        {
            var current = WinProxy.Read();
            if (current == before || current == restored)
            {
                Save(lease);
                if (current != before)
                    WinProxy.Write(before);
            }
            throw;
        }
    });

    internal static int Watch(ProcessIdentity owner, string signal)
    {
        using var ready = EventWaitHandle.OpenExisting(signal);
        ProcessIdentity guard = ProcessIdentity.Current();
        ready.Set();
        while (true)
        {
            try
            {
                bool done = Locked(() =>
                {
                    bool ownerAlive = owner.IsAlive();
                    if (Read() is { } lease && lease.Guard == guard && lease.Owner == owner &&
                        (!ownerAlive || !lease.Core.IsAlive() || !lease.Owns(WinProxy.Read())))
                        Restore(lease);
                    return !ownerAlive;
                });
                if (done)
                    return 0;
            }
            catch (Exception)
            {
                // Leave the journal in place and retry. The app also restores it on a later launch.
            }
            Thread.Sleep(250);
        }
    }

    private static void Restore(Lease lease)
    {
        var current = WinProxy.Read();
        if (lease.Owns(current))
        {
            var restored = RestoreAvailableProxy(lease);
            if (!restored.MatchesActiveSettings(current))
                WinProxy.Write(restored);
        }
        File.Delete(Path);
    }

    private static ProxySettings RestoreAvailableProxy(Lease lease, string? newListener = null)
    {
        var original = lease.Original;
        if ((original.Flags & 2) == 0)
            return original;

        foreach (string entry in original.Server.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            string server = entry[(entry.IndexOf('=') + 1)..];
            string address = server.Contains("://", StringComparison.Ordinal) ? server : $"http://{server}";
            if (!Uri.TryCreate(address, UriKind.Absolute, out var uri) || !uri.IsLoopback)
                continue;
            bool ownListener = (newListener is not null && uri.Port == TryPort(newListener)) ||
                (uri.Port == TryPort(lease.Endpoint) && lease.Owner.IsAlive());
            if (ownListener || !Listening(uri))
                return original with { Flags = (original.Flags & ~2u) | 1 };
        }
        return original;

        static int TryPort(string endpoint) => IPEndPoint.TryParse(endpoint, out var address) ? address.Port : -1;

        static bool Listening(Uri endpoint)
        {
            using var client = new TcpClient();
            using var timeout = new CancellationTokenSource(TimeSpan.FromMilliseconds(250));
            try
            {
                client.ConnectAsync(endpoint.IdnHost.Trim('[', ']'), endpoint.Port, timeout.Token).AsTask().GetAwaiter().GetResult();
                return true;
            }
            catch (Exception error) when (error is SocketException or OperationCanceledException) { return false; }
        }
    }

    private static Lease? Read() => File.Exists(Path)
        ? JsonSerializer.Deserialize<Lease>(File.ReadAllBytes(Path)) ??
          throw new InvalidDataException(L10n.Text("无法读取代理恢复记录。"))
        : null;

    private static void Save(Lease lease) => Program.WriteAtomic(Path, JsonSerializer.SerializeToUtf8Bytes(lease));

    private static void Locked(Action action) => Locked(() => { action(); return true; });

    private static T Locked<T>(Func<T> action)
    {
        using var mutex = new Mutex(false, $@"Global\Byway.Proxy.{Program.UserId}");
        try
        {
            if (!mutex.WaitOne(TimeSpan.FromSeconds(5)))
                throw new TimeoutException(L10n.Text("等待 Windows 系统代理设置超时。"));
        }
        catch (AbandonedMutexException) { } // The journal was written atomically before any proxy change.
        try { return action(); }
        finally { mutex.ReleaseMutex(); }
    }
}
