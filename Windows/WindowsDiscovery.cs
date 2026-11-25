using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;

namespace Byway;

internal sealed class WindowsDiscovery : IDisposable
{
    private readonly object gate = new();
    private volatile DiscoveryState state = new(true, "waiting");
    private (Guid Device, IPAddress Address, uint Index)? target;
    private CancellationTokenSource? lifetime;
    private Task pending = Task.CompletedTask;

    internal DiscoveryState State => state;

    internal void Update(bool enabled, Guid? device, IPAddress? address, uint index, int port, bool active, string? host)
    {
        lock (gate)
        {
            string? ipUrl = address is null ? null : $"http://{address}:{port}/";
            if (!enabled || !active || device is null || address is null || index == 0 || host is null)
            {
                Stop();
                state = new(enabled, !enabled ? "off" : active && address is not null ? "unavailable" : "waiting", IpUrl: ipUrl);
                return;
            }

            var requested = (device.Value, address, index);
            if (target == requested) return;
            Stop();
            target = requested;
            var next = new CancellationTokenSource();
            lifetime = next;
            state = new(true, "publishing", IpUrl: ipUrl);
            string label = DiscoveryState.Label(device.Value);
            Task previous = pending;
            pending = Task.Run(async () =>
            {
                try
                {
                    await previous;
                    if (!next.IsCancellationRequested)
                        await PublishAsync(label, host, address, index, (ushort)port, next.Token, success =>
                        {
                            lock (gate)
                            {
                                if (lifetime == next && !next.IsCancellationRequested)
                                    state = new(true, success ? "published" : "unavailable",
                                        success ? $"http://{host}:{port}/" : null, ipUrl);
                            }
                        });
                }
                catch (Exception error) when (error is DllNotFoundException or EntryPointNotFoundException or InvalidOperationException)
                {
                    lock (gate)
                    {
                        if (lifetime == next && !next.IsCancellationRequested)
                            state = new(true, "unavailable", IpUrl: ipUrl);
                    }
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
    }

    private void Stop()
    {
        target = null;
        if (lifetime is not { } previous) return;
        lifetime = null;
        previous.Cancel();
        if (pending.IsCompleted) previous.Dispose();
    }

    public void Dispose()
    {
        lock (gate)
        {
            Stop();
            state = new(false, "off");
        }
    }

    private static async Task PublishAsync(string label, string host, IPAddress address, uint index, ushort port,
        CancellationToken cancellation, Action<bool> published)
    {
        nint instance = 0;
        bool registered = false;
        try
        {
            var resolved = await Dns.GetHostAddressesAsync(host, AddressFamily.InterNetwork, cancellation)
                .WaitAsync(TimeSpan.FromSeconds(3), cancellation);
            if (!resolved.Contains(address))
            {
                published(false);
                return;
            }
            uint ipv4 = BitConverter.ToUInt32(address.GetAddressBytes());
            instance = DnsServiceConstructInstance(label + "._http._tcp.local", host, ref ipv4, 0, port, 0, 0, 0, 0, 0);
            if (instance == 0) { published(false); return; }
            // Keep request memory alive until Windows reports its asynchronous result.
            var registration = SendAsync(instance, index, register: true);
            try { registered = await registration.WaitAsync(TimeSpan.FromSeconds(5), cancellation) == 0; }
            catch (TimeoutException)
            {
                published(false);
                registered = await registration == 0;
                return;
            }
            catch (OperationCanceledException)
            {
                registered = await registration == 0;
                return;
            }
            published(registered);
            if (registered) await Task.Delay(Timeout.Infinite, cancellation);
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
        catch (Exception error) when (error is DllNotFoundException or EntryPointNotFoundException or SocketException or TimeoutException)
        {
            published(false);
        }
        finally
        {
            if (registered) await SendAsync(instance, index, register: false);
            if (instance != 0) DnsServiceFreeInstance(instance);
        }
    }

    private sealed record Completion(nint Instance, TaskCompletionSource<uint> Task);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate void CompletionCallback(uint status, nint context, nint result);

    private static readonly CompletionCallback Completed = (status, context, result) =>
    {
        var completion = (Completion)GCHandle.FromIntPtr(context).Target!;
        if (result != 0 && result != completion.Instance)
            DnsServiceFreeInstance(result);
        completion.Task.TrySetResult(status);
    };

    private static async Task<uint> SendAsync(nint instance, uint interfaceIndex, bool register)
    {
        var completion = new TaskCompletionSource<uint>(TaskCreationOptions.RunContinuationsAsynchronously);
        var context = GCHandle.Alloc(new Completion(instance, completion));
        nint request = Marshal.AllocHGlobal(Marshal.SizeOf<RegisterRequest>());
        try
        {
            Marshal.StructureToPtr(new RegisterRequest
            {
                Version = 1, InterfaceIndex = interfaceIndex, Instance = instance,
                Callback = Marshal.GetFunctionPointerForDelegate(Completed), Context = GCHandle.ToIntPtr(context)
            }, request, false);
            uint status = register ? DnsServiceRegister(request, 0) : DnsServiceDeRegister(request, 0);
            return status == 9506 ? await completion.Task : status;
        }
        finally
        {
            Marshal.FreeHGlobal(request);
            context.Free();
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RegisterRequest
    {
        internal uint Version, InterfaceIndex;
        internal nint Instance, Callback, Context, Credentials;
        internal int UnicastEnabled;
    }

    [DllImport("dnsapi.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern nint DnsServiceConstructInstance(string service, string host, ref uint ipv4, nint ipv6,
        ushort port, ushort priority, ushort weight, uint properties, nint keys, nint values);
    [DllImport("dnsapi.dll", ExactSpelling = true)]
    private static extern uint DnsServiceRegister(nint request, nint cancel);
    [DllImport("dnsapi.dll", ExactSpelling = true)]
    private static extern uint DnsServiceDeRegister(nint request, nint cancel);
    [DllImport("dnsapi.dll", ExactSpelling = true)]
    private static extern void DnsServiceFreeInstance(nint instance);
}
