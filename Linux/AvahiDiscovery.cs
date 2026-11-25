using System.Diagnostics;
using Byway;

internal sealed class AvahiDiscovery(Guid id, string? ip, int port, string preferenceFile, Action<DiscoveryState> changed) : IAsyncDisposable
{
    private readonly object gate = new();
    private volatile DiscoveryState state = new(true, "waiting");
    private CancellationTokenSource? lifetime;
    private Task pending = Task.CompletedTask;

    internal DiscoveryState State => state;

    internal void Start()
    {
        lock (gate)
        {
            bool enabled;
            try { enabled = File.ReadAllText(preferenceFile).Trim() == "true"; }
            catch (FileNotFoundException) { enabled = true; }
            catch (DirectoryNotFoundException) { enabled = true; }
            Replace(enabled);
        }
    }

    internal DiscoveryState SetEnabled(bool enabled)
    {
        lock (gate)
        {
            if (state.Enabled != enabled)
            {
                Directory.CreateDirectory(Path.GetDirectoryName(preferenceFile)!);
                string temp = preferenceFile + ".tmp";
                try
                {
                    File.WriteAllText(temp, enabled ? "true" : "false");
                    File.Move(temp, preferenceFile, overwrite: true);
                }
                finally { File.Delete(temp); }
                Replace(enabled);
            }
            return State;
        }
    }

    private void Replace(bool enabled)
    {
        var previous = lifetime;
        previous?.Cancel();
        lifetime = null;
        if (pending.IsCompleted) previous?.Dispose();
        string? ipUrl = ip is null ? null : $"http://{ip}:{port}/";
        Publish(new(enabled, !enabled ? "off" : ip is null ? "waiting" : "publishing", IpUrl: ipUrl));
        if (!enabled || ip is null)
            return;

        var next = lifetime = new CancellationTokenSource();
        Task cleanup = pending;
        pending = Task.Run(async () =>
        {
            await cleanup;
            try
            {
                await RunAsync(ip, next, ipUrl!);
            }
            finally
            {
                lock (gate)
                {
                    if (lifetime != next)
                        next.Dispose();
                }
            }
        });
    }

    private async Task RunAsync(string address, CancellationTokenSource source, string ipUrl)
    {
        var cancellation = source.Token;
        string label = DiscoveryState.Label(id);
        string host = label + ".local";
        Process? alias = null;
        Process? service = null;
        try
        {
            cancellation.ThrowIfCancellationRequested();
            alias = StartPublisher("-a", "-R", host, address);
            await WaitForNameAsync(alias, host, cancellation);
            service = StartPublisher("-s", "-H", host, label, "_http._tcp", port.ToString(System.Globalization.CultureInfo.InvariantCulture));
            await WaitForNameAsync(service, label, cancellation);
            lock (gate)
            {
                if (lifetime == source && !cancellation.IsCancellationRequested)
                    Publish(new(true, "published", $"http://{host}:{port}/", ipUrl));
            }
            await Task.WhenAny(WaitForLossAsync(alias, cancellation), WaitForLossAsync(service, cancellation));
            cancellation.ThrowIfCancellationRequested();
            throw new IOException("Avahi registration ended.");
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
        catch (Exception error) when (error is IOException or TimeoutException or System.ComponentModel.Win32Exception)
        {
            lock (gate)
            {
                if (lifetime == source && !cancellation.IsCancellationRequested)
                    Publish(new(true, "unavailable", IpUrl: ipUrl));
            }
        }
        finally
        {
            await StopAsync(service);
            await StopAsync(alias);
        }
    }

    private static Process StartPublisher(params string[] arguments)
    {
        var start = new ProcessStartInfo("avahi-publish")
        {
            UseShellExecute = false, RedirectStandardError = true
        };
        start.Environment["LC_ALL"] = "C";
        foreach (string argument in arguments) start.ArgumentList.Add(argument);
        return Process.Start(start) ?? throw new IOException("Avahi publisher did not start.");
    }

    private static async Task WaitForNameAsync(Process process, string name, CancellationToken cancellation)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        timeout.CancelAfter(TimeSpan.FromSeconds(5));
        try
        {
            while (await process.StandardError.ReadLineAsync(timeout.Token) is { } line)
            {
                if (line == $"Established under name '{name}'") return;
                if (line.Contains("collision", StringComparison.OrdinalIgnoreCase) ||
                    line.StartsWith("Established under name", StringComparison.Ordinal))
                    throw new IOException("The mDNS name is already in use.");
            }
            throw new IOException("Avahi ended before publishing the name.");
        }
        catch (OperationCanceledException) when (!cancellation.IsCancellationRequested)
        {
            throw new TimeoutException("Avahi did not confirm publication.");
        }
    }

    private static async Task WaitForLossAsync(Process process, CancellationToken cancellation)
    {
        while (await process.StandardError.ReadLineAsync(cancellation) is { } line)
        {
            if (line.Contains("collision", StringComparison.OrdinalIgnoreCase) ||
                line.Contains("disconnected", StringComparison.OrdinalIgnoreCase) ||
                line.StartsWith("Failed", StringComparison.Ordinal))
                return;
        }
    }

    private static async Task StopAsync(Process? process)
    {
        if (process is null) return;
        using (process)
        {
            if (!process.HasExited)
            {
                try { process.Kill(); }
                catch (InvalidOperationException) { }
            }
            await process.WaitForExitAsync();
        }
    }

    private void Publish(DiscoveryState next)
    {
        state = next;
        changed(next);
    }

    public async ValueTask DisposeAsync()
    {
        Task cleanup;
        lock (gate)
        {
            var previous = lifetime;
            lifetime = null;
            previous?.Cancel();
            if (pending.IsCompleted) previous?.Dispose();
            cleanup = pending;
        }
        await cleanup;
    }
}
