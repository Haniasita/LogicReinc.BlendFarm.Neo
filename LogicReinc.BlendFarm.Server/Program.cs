using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace LogicReinc.BlendFarm.Server
{
    //Should clean this up.
    //Contains lots of test code
    public class Program
    {
        public const int VersionMajor = 1;
        public const int VersionMinor = 0;
        public const int VersionPatch = 5;

        public static RenderServer Server { get; private set; }

        public static event Action<string> OnConsoleOutput;

        private static ConsoleRedirector _redirector = null;

        private static int sleepTimer;

        public static void StartIntercepting()
        {
            if (_redirector == null)
            {
                _redirector = new ConsoleRedirector(Console.Out);
                _redirector.OnWrite += (output) => OnConsoleOutput?.Invoke(output);
                Console.SetOut(_redirector);
            }
        }

        static void Main(string[] args)
        {
            StartIntercepting();

            // Parse command-line arguments
            for (int i = 0; i < args.Length; i++)
            {
                if (args[i] == "--port" && i + 1 < args.Length)
                {
                    if (int.TryParse(args[i + 1], out int port))
                        ServerSettings.Instance.Port = port;
                    else
                        Console.WriteLine($"[WARNING] Invalid port value: {args[i + 1]}");
                }
                if (args[i] == "--broadcast-port" && i + 1 < args.Length)
                {
                    if (int.TryParse(args[i + 1], out int broadcastPort))
                        ServerSettings.Instance.BroadcastPort = broadcastPort;
                    else
                        Console.WriteLine($"[WARNING] Invalid broadcast port value: {args[i + 1]}");
                }
                if (args[i] == "--enable-auto-sleep")
                {
                    ServerSettings.Instance.EnableAutoSleep = true;
                }
                if (args[i] == "--auto-sleep-timeout" && i + 1 < args.Length)
                {
                    if (int.TryParse(args[i + 1], out int timeout))
                        ServerSettings.Instance.AutoSleepTimeoutSeconds = timeout;
                    else
                        Console.WriteLine($"[WARNING] Invalid auto-sleep timeout value: {args[i + 1]}");
                }
            }

            try
            {
                //List IP addreses of this machine
                string[] addresses = Dns.GetHostEntry(Dns.GetHostName()).AddressList
                    .Where(x => x.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork).Select(x => x?.ToString())
                    .ToArray();
                Console.WriteLine("IP Addresses of this Server:");
                for (int i = 0; i < addresses.Length; i++)
                {
                    string address = addresses[i];
                    Console.WriteLine($"Host Address #{(i + 1)}: {address}");
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[WARNING] Failed to obtain host address due to [{ex.GetType().Name}]: {ex.Message}");
            }
            //List host port
            Console.WriteLine($"Port: {ServerSettings.Instance.Port}");

            //Clears any sessions left after previous close
            Console.WriteLine("Cleaning up old sessions..");
            CleanupOldSessions();

            //RenderNode Server
            Server = new RenderServer(ServerSettings.Instance.Port, ServerSettings.Instance.BroadcastPort, true);

            Server.Start();
            Console.WriteLine("Server Started");

            // Calculate sleep timer iterations based on timeout setting (500ms per iteration)
            int sleepIterations = (ServerSettings.Instance.AutoSleepTimeoutSeconds * 1000) / 500;
            sleepTimer = sleepIterations;

            //ReadLines in main loop removed for deployment as this can freeze background threads under specific conditions
            while (true)
            {
                if (Server.Clients.Count == 0)
                {
                    sleepTimer--;
                    if (sleepTimer == 0)
                    {
                        sleepTimer = sleepIterations;
                        if (ServerSettings.Instance.EnableAutoSleep)
                            SystemSleep.Suspend();
                    }
                }
                else sleepTimer = sleepIterations;

                Thread.Sleep(500);
            }
        }

        /// <summary>
        /// Deletes the BlenderFiles directory, which is used for temporary file storage
        /// </summary>
        public static void CleanupOldSessions()
        {
            try
            {
                string path = SystemInfo.RelativeToApplicationDirectory(ServerSettings.Instance.BlenderFiles);
                if (Directory.Exists(path))
                    Directory.Delete(path, true);
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[WARNING] Failed to cleanup old sessions: {ex.Message}");
            }
        }




        private class ConsoleRedirector : TextWriter
        {
            public override Encoding Encoding => Encoding.UTF8;

            private TextWriter _parent = null;

            public event Action<string> OnWrite;

            public ConsoleRedirector(TextWriter parent)
            {
                _parent = parent;
            }

            public override void Write(string value)
            {
                OnWrite?.Invoke(value);
                _parent?.Write(value);
            }
            public override void WriteLine(string value)
            {
                OnWrite?.Invoke(value);
                _parent?.WriteLine(value);
            }

            public override Task WriteAsync(string value)
            {
                OnWrite?.Invoke(value + "\n");
                return _parent?.WriteAsync(value);
            }
            public override Task WriteLineAsync(string value)
            {
                OnWrite?.Invoke(value + "\n");
                return _parent?.WriteLineAsync(value);
            }
        }

    }
}

