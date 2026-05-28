using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace LogicReinc.BlendFarm.Server
{
    /// <summary>
    /// Cross-platform system sleep/suspend functionality
    /// </summary>
    public static class SystemSleep
    {
        [DllImport("PowrProf.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetSuspendState(bool hibernate, bool forceCritical, bool disableWakeEvent);

        /// <summary>
        /// Suspends/sleeps the system (hibernation on Windows)
        /// </summary>
        public static void Suspend()
        {
            try
            {
                if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
                {
                    SuspendWindows();
                }
                else if (RuntimeInformation.IsOSPlatform(OSPlatform.Linux))
                {
                    SuspendLinux();
                }
                else if (RuntimeInformation.IsOSPlatform(OSPlatform.OSX))
                {
                    SuspendMacOS();
                }
                else
                {
                    Console.WriteLine("[WARNING] System suspend not supported on this platform");
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[WARNING] Failed to suspend system: {ex.Message}");
            }
        }

        private static void SuspendWindows()
        {
            bool success = SetSuspendState(true, false, true);
            if (!success)
            {
                throw new InvalidOperationException("SetSuspendState failed");
            }
            Console.WriteLine("System entering hibernation...");
        }

        private static void SuspendLinux()
        {
            try
            {
                // Assumes systemd is being used and the user has permission to suspend without sudo.
                // If you do not use systemd or need sudo, you may need to adjust this command!!
                ExecuteCommand("systemctl", "suspend");
            }
            catch
            {
                throw new InvalidOperationException("systemctl suspend failed - may require appropriate permissions or systemd not available");
            }
            Console.WriteLine("System entering sleep...");
        }

        private static void SuspendMacOS()
        {
            ExecuteCommand("pmset", "sleepnow");
            Console.WriteLine("System entering sleep...");
        }

        private static void ExecuteCommand(string fileName, string arguments)
        {
            using (Process process = new Process())
            {
                process.StartInfo.FileName = fileName;
                process.StartInfo.Arguments = arguments;
                process.StartInfo.UseShellExecute = false;
                process.StartInfo.RedirectStandardError = true;
                process.StartInfo.CreateNoWindow = true;

                if (!process.Start())
                {
                    throw new InvalidOperationException($"Failed to execute {fileName}");
                }

                process.WaitForExit();

                if (process.ExitCode != 0)
                {
                    string error = process.StandardError.ReadToEnd();
                    throw new InvalidOperationException($"{fileName} failed with exit code {process.ExitCode}: {error}");
                }
            }
        }
    }
}
