using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Byway;

internal sealed partial class Job : IDisposable
{
    private readonly SafeFileHandle handle = CreateJobObject(IntPtr.Zero, IntPtr.Zero);

    internal unsafe Job()
    {
        var limits = new ExtendedLimits { Basic = new BasicLimits { Flags = 0x2000 } }; // KILL_ON_JOB_CLOSE
        if (!handle.IsInvalid && SetInformationJobObject(handle, 9, &limits, sizeof(ExtendedLimits)))
            return;
        int error = Marshal.GetLastPInvokeError();
        handle.Dispose();
        throw new Win32Exception(error);
    }

    internal void Attach(Process process)
    {
        if (!AssignProcessToJobObject(handle, process.SafeHandle))
            throw new Win32Exception(Marshal.GetLastPInvokeError());
    }

    public void Dispose() => handle.Dispose();

    [StructLayout(LayoutKind.Sequential)]
    private struct BasicLimits
    {
        internal long ProcessTime, JobTime;
        internal uint Flags;
        internal nuint MinimumWorkingSet, MaximumWorkingSet;
        internal uint ActiveProcesses;
        internal nuint Affinity;
        internal uint Priority, Scheduling;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IoCounters
    {
        internal ulong ReadOperations, WriteOperations, OtherOperations, ReadBytes, WriteBytes, OtherBytes;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ExtendedLimits
    {
        internal BasicLimits Basic;
        internal IoCounters Io;
        internal nuint ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
    }

    [LibraryImport("kernel32.dll", EntryPoint = "CreateJobObjectW", SetLastError = true)]
    private static partial SafeFileHandle CreateJobObject(IntPtr attributes, IntPtr name);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static unsafe partial bool SetInformationJobObject(SafeFileHandle job, int kind, void* info, int size);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool AssignProcessToJobObject(SafeFileHandle job, SafeProcessHandle process);
}
