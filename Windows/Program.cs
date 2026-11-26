using System.Diagnostics;
using System.Security.Principal;
using System.Windows;

namespace Byway;

internal static class Program
{
    internal static readonly string UserId = WindowsIdentity.GetCurrent().User!.Value;
    internal static readonly bool IsElevated = ReadElevation();
    private static readonly string DataFolder = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Byway", "Data");

    internal static string StatePath(string name) => Path.Combine(DataFolder, name);

    [STAThread]
    internal static int Main(string[] args)
    {
        if (args is [LanFirewall.ProvisionArgument])
            return LanFirewall.RunProvisioning();

        if (args is ["--watch", var pid, var started, var signal] &&
            int.TryParse(pid, out int owner) && long.TryParse(started, out long time))
            return ProxyLease.Watch(new(owner, time), signal);

        try
        {
            bool restarted = false;
            if (args is ["--restart-elevated", var oldPid, var oldStart] && IsElevated &&
                int.TryParse(oldPid, out int previousPid) && long.TryParse(oldStart, out long previousStart))
            {
                WaitForPreviousInstance(previousPid, previousStart);
                restarted = true;
            }
            Directory.CreateDirectory(DataFolder);
            using var show = new EventWaitHandle(false, EventResetMode.AutoReset, $@"Local\Byway.Show.{UserId}");
            FileStream instance;
            try { instance = File.Open(StatePath("instance.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None); }
            catch (IOException error) when ((error.HResult & 0xffff) == 32)
            {
                show.Set();
                return 0;
            }

            using (instance)
            {
                ProxyLease.RecoverAtLaunch();
                var app = new App();
                app.InitializeComponent();
                System.Windows.Forms.WindowsFormsSynchronizationContext.AutoInstall = false;
                using var window = new MainWindow(show, SavedProfile.Load(), args is ["--login"], restarted,
                    resumeAfterUpgrade: args is ["--resume-after-upgrade"]);
                app.SessionEnding += (_, _) => ProxyLease.Release();
                return app.Run(window);
            }
        }
        catch (Exception error)
        {
            if (Environment.UserInteractive)
                MessageBox.Show(L10n.Format($"Byway 无法启动。\n{error.Message}"), "Byway", MessageBoxButton.OK, MessageBoxImage.Error);
            return 1;
        }
    }

    private static bool ReadElevation()
    {
        using var identity = WindowsIdentity.GetCurrent();
        return new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
    }

    private static void WaitForPreviousInstance(int pid, long start)
    {
        try
        {
            using var process = Process.GetProcessById(pid);
            if (process.StartTime.ToFileTimeUtc() == start)
                process.WaitForExit(12_000);
        }
        catch (ArgumentException) { }
        catch (InvalidOperationException) { }
    }

    internal static Process StartGuard()
    {
        string signal = $@"Local\Byway.Guard.{Guid.NewGuid():N}";
        using var ready = new EventWaitHandle(false, EventResetMode.ManualReset, signal);
        var owner = ProcessIdentity.Current();
        var info = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false, CreateNoWindow = true };
        foreach (var argument in new[] { "--watch", owner.Pid.ToString(), owner.Started.ToString(), signal })
            info.ArgumentList.Add(argument);
        Process guard = Process.Start(info) ?? throw new InvalidOperationException(L10n.Text("无法启动代理恢复进程。"));
        if (ready.WaitOne(TimeSpan.FromSeconds(4)) && !guard.HasExited)
            return guard;
        guard.Dispose();
        throw new InvalidOperationException(L10n.Text("代理恢复进程未就绪。"));
    }

    internal static void WriteAtomic(string path, byte[] bytes)
    {
        string temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using (var stream = File.Open(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                stream.Write(bytes);
                stream.Flush(flushToDisk: true);
            }
            File.Move(temporary, path, overwrite: true);
        }
        finally { File.Delete(temporary); }
    }
}

public partial class App : Application { }
