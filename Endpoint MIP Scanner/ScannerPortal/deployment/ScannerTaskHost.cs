using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;

internal static class ScannerTaskHost
{
    [StructLayout(LayoutKind.Sequential)]
    private struct BasicLimits
    {
        public long ProcessTime, JobTime;
        public uint Flags;
        public UIntPtr MinimumWorkingSet, MaximumWorkingSet;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ExtendedLimits
    {
        public BasicLimits Basic;
        public ulong ReadOperations, WriteOperations, OtherOperations, ReadBytes, WriteBytes, OtherBytes;
        public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr CreateJobObject(IntPtr attributes, IntPtr name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(IntPtr job, int informationClass, ref ExtendedLimits limits, uint length);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();

    private static int Main(string[] args)
    {
        if (args.Length != 1 || !Path.IsPathRooted(args[0]) || args[0].Contains("\""))
            return 2;

        string directory = Path.GetFullPath(args[0]);
        try
        {
            // Keep the scanner in the task's process tree even when the task is forcibly stopped.
            IntPtr job = CreateJobObject(IntPtr.Zero, IntPtr.Zero);
            if (job == IntPtr.Zero)
                throw new Win32Exception(Marshal.GetLastWin32Error());
            var limits = new ExtendedLimits();
            limits.Basic.Flags = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            if (!SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf(typeof(ExtendedLimits))) ||
                !AssignProcessToJobObject(job, GetCurrentProcess()))
                throw new Win32Exception(Marshal.GetLastWin32Error());

            // The OS closes the private job handle when this host exits.
            string runner = Path.GetFullPath(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "..", "Invoke-ScannerPortalEndpoint.ps1"));
            var start = new ProcessStartInfo
            {
                FileName = Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe"),
                Arguments = "-NoProfile -NonInteractive -File " + Quote(runner) + " -Directory " + Quote(directory) + " -Continuous",
                WorkingDirectory = Path.GetDirectoryName(runner),
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardError = true
            };
            using (Process scanner = Process.Start(start))
            {
                scanner.ErrorDataReceived += (sender, data) =>
                {
                    if (!String.IsNullOrEmpty(data.Data))
                        Log(directory, data.Data);
                };
                scanner.BeginErrorReadLine();
                scanner.WaitForExit();
                return scanner.ExitCode;
            }
        }
        catch (Exception error)
        {
            Log(directory, error.Message);
            return 1;
        }
    }

    private static string Quote(string path)
    {
        int trailingSlashes = path.Length - path.TrimEnd('\\').Length;
        return "\"" + path + new string('\\', trailingSlashes) + "\"";
    }

    private static void Log(string directory, string message)
    {
        try
        {
            string log = Path.Combine(directory, "task-startup-error.log");
            if (!File.Exists(log) || new FileInfo(log).Length < 65536)
                File.AppendAllText(log, DateTime.UtcNow.ToString("o") + " " + message + Environment.NewLine);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
}
