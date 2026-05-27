using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.ExceptionServices;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace LogicReinc.BlendFarm.Server
{
    /// <summary>
    /// Represents a single blender process instance
    /// </summary>
    public partial class BlenderProcess(string blender, string args, string version = null, string file = null, long fileId = -1)
    {
        private static readonly Regex REGEX_Progress = BlenderRegex();
        private static readonly Regex REGEX_Progress2 = BlenderRegex2();

        private readonly object _continueLock = new();
        private readonly object _lineLock = new();
        private string _progressFilePath = null;
        private Timer _progressMonitorTimer = null;

        public const int CONTINUE_TIMEOUT = 10000;

        public string CMD { get; private set; } = blender;
        public string ARG { get; private set; } = args;
        public event Action<string> OnBlenderOutput;

        public Process Process { get; private set; }
        public bool Active { get; private set; }

        public string Version { get; private set; } = version;
        public string File { get; private set; } = file;
        public long FileID { get; private set; } = fileId;

        public bool IsContinueing { get; private set; }

        /// <summary>
        /// Called when a task is complete with ID
        /// </summary>
        public event Action<string> OnBlenderCompleteTask;
        /// <summary>
        /// Called when an exception is caught by script
        /// </summary>
        public event Action<string> OnBlenderException;
        /// <summary>
        /// Called when a render status update is received
        /// </summary>
        public event Action<Status> OnBlenderStatus;

        public event Action<BlenderProcess> OnBlenderContinue;

        public int ContinueCount { get; private set; }

        public List<string> Results { get; private set; } = [];
        public List<string> Exceptions { get; private set; } = [];

        private void HandleContinue()
        {
            IsContinueing = true;
            OnBlenderContinue?.Invoke(this);
            int currentCount = 0;

            lock (_continueLock)
            {
                currentCount = ContinueCount + 1;
                ContinueCount = currentCount;
            }
            if (CONTINUE_TIMEOUT == 0)
                Cancel();
            else
            {
                Task.Delay(CONTINUE_TIMEOUT).ContinueWith((x) =>
                {
                    if (ContinueCount == currentCount && IsContinueing)
                    {
                        Console.WriteLine($"Continuation timeout, ending process..");
                        Cancel();
                    }
                });
            }
        }

        /// <summary>
        /// Starts the process and handle output
        /// </summary>
        public Result Run()
        {
            Process process = new()
            {
                StartInfo = new()
                {
                    FileName = CMD,
                    Arguments = ARG,
                    UseShellExecute = false,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    RedirectStandardInput = true,
                    CreateNoWindow = true
                }
            };
            process.Exited += (a, b) => Active = false;
            Process = process;
            process.Start();
            Active = true;

            // Some Blender builds emit Cycles progress lines (and other render
            // output) to stderr rather than stdout, especially for OptiX/HIP.
            // Drain stderr on a background thread so those lines hit the same
            // regex parser as stdout. Reading just one stream and leaving the
            // other to fill the pipe buffer can also deadlock the child.
            _ = Task.Run(() =>
            {
                try
                {
                    while (!process.StandardError.EndOfStream)
                    {
                        var line = process.StandardError.ReadLine();
                        if (line != null)
                            ProcessBlenderLine(line);
                    }
                }
                catch { }
            });

            while (!process.StandardOutput.EndOfStream)
            {
                var line = process.StandardOutput.ReadLine();
                if (ProcessBlenderLine(line))
                    return new Result()
                    {
                        Results = [.. Results],
                        Exceptions = [.. Exceptions]
                    };
            }

            process.WaitForExit();
            return new Result()
            {
                Results = [.. Results],
                Exceptions = [.. Exceptions]
            };
        }

        public void Continue(string newPath)
        {
            lock (_continueLock)
            {
                if (!IsContinueing)
                    throw new InvalidOperationException("Attempting to continue a process that is not in continue state");
                IsContinueing = false;
            }
            Process.StandardInput.WriteLine(newPath);
            while (!Process.StandardOutput.EndOfStream)
            {
                var line = Process.StandardOutput.ReadLine();
                if (ProcessBlenderLine(line))
                    return;
            }

            Process.WaitForExit();
        }

        /// <summary>
        /// Cancel the process
        /// </summary>
        public void Cancel()
        {
            IsContinueing = false;
            Active = false;
            Process?.Kill();
        }


        /// <summary>
        /// Handles a Blender print line
        /// </summary>
        /// <param name="line"></param>
        private void StartProgressMonitoring(string taskId)
        {
            StopProgressMonitoring();

            // Try to find the render output directory from recent render operations
            // The progress file will be in the same directory as the render output
            string progressFileName = taskId + ".progress.json";

            // We'll search for this file in common render directories
            _progressMonitorTimer = new Timer(_ => CheckProgressFile(), null, TimeSpan.FromMilliseconds(100), TimeSpan.FromMilliseconds(500));
        }

        private void StopProgressMonitoring()
        {
            _progressMonitorTimer?.Dispose();
            _progressMonitorTimer = null;
            _progressFilePath = null;
        }

        private void CheckProgressFile()
        {
            try
            {
                // If we haven't found the file yet, search for it
                if (string.IsNullOrEmpty(_progressFilePath))
                {
                    string progressDir = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "BlendFarmProgress");
                    if (System.IO.Directory.Exists(progressDir))
                    {
                        var progressFiles = System.IO.Directory.GetFiles(progressDir, "*.progress.json");
                        if (progressFiles.Length > 0)
                        {
                            // Use the most recently modified file
                            _progressFilePath = progressFiles.OrderByDescending(f => new System.IO.FileInfo(f).LastWriteTime).First();
                        }
                    }
                }

                if (string.IsNullOrEmpty(_progressFilePath) || !System.IO.File.Exists(_progressFilePath))
                {
                    return;
                }

                string json = System.IO.File.ReadAllText(_progressFilePath);
                var progressData = JsonDocument.Parse(json).RootElement;

                int tilesFinished = progressData.GetProperty("TilesFinished").GetInt32();
                int tilesTotal = progressData.GetProperty("TilesTotal").GetInt32();

                string phase = null;
                if (progressData.TryGetProperty("Phase", out var phaseElement) && phaseElement.ValueKind == JsonValueKind.String)
                    phase = phaseElement.GetString();

                int elapsed = 0;
                if (progressData.TryGetProperty("Elapsed", out var elapsedElement) && elapsedElement.ValueKind == JsonValueKind.Number)
                    elapsed = (int)elapsedElement.GetDouble();

                int remaining = -1;
                if (progressData.TryGetProperty("Remaining", out var remainingElement) && remainingElement.ValueKind == JsonValueKind.Number)
                    remaining = (int)remainingElement.GetDouble();

                // If no progress counts were parsed (TilesFinished/Total are 0), try to extract from status message
                if (tilesFinished == 0 && tilesTotal == 0 && phase != null)
                {
                    var countMatch = System.Text.RegularExpressions.Regex.Match(phase, @"(\d+)\s*/\s*(\d+)");
                    if (countMatch.Success)
                    {
                        tilesFinished = int.Parse(countMatch.Groups[1].Value);
                        tilesTotal = int.Parse(countMatch.Groups[2].Value);
                    }
                }

                OnBlenderStatus?.Invoke(new Status()
                {
                    TilesFinish = tilesFinished,
                    TilesTotal = tilesTotal,
                    Phase = phase,
                    Time = elapsed,
                    TimeRemaining = remaining
                });
            }
            catch
            {
                // Silently ignore file read errors
            }
        }

        private bool ProcessBlenderLine(string line)
        {
            // Serialize because stdout and stderr are now drained on separate
            // threads — both feed this method, and Results/Exceptions/event
            // invocations need to stay coherent.
            lock (_lineLock)
            {
                Console.WriteLine(line);

                try
                {
                    Match match = REGEX_Progress.Match(line);
                    if (match == null || !match.Success || match.Groups.Count != 5)
                        match = REGEX_Progress2.Match(line);

                    //Handle Status
                    if (OnBlenderStatus != null && match != null && match.Success && match.Groups.Count == 5)
                    {
                        string timeStr = match.Groups[1].Value.Trim();
                        string remainStr = match.Groups[2].Value.Trim();
                        string renderedStr = match.Groups[3].Value.Trim();
                        string tilesTotalStr = match.Groups[4].Value.Trim();


                        OnBlenderStatus?.Invoke(new Status()
                            {
                                TilesFinish = int.Parse(renderedStr),
                                TilesTotal = int.Parse(tilesTotalStr),

                                //TODO: Proper time parsing, if even bother at all
                                //Time = (int)TimeSpan.Parse(timeStr).TotalSeconds,
                                //TimeRemaining = (int)TimeSpan.Parse(remainStr).TotalSeconds
                            });
                    }
                    else if (line.StartsWith("EXCEPTION:"))
                    {
                        string exception = line["EXCEPTION:".Length..];
                        OnBlenderException?.Invoke(exception);
                        Exceptions.Add(exception);
                    }
                    else if (line.StartsWith("RENDER_START:"))
                    {
                        string taskId = line["RENDER_START:".Length..].Trim();
                        StartProgressMonitoring(taskId);
                    }
                    else if (line.StartsWith("SUCCESS:"))
                    {
                        string result = line["SUCCESS:".Length..];
                        StopProgressMonitoring();
                        OnBlenderCompleteTask?.Invoke(result);
                        Results.Add(result);
                    }
                    else if (line.StartsWith("AWAITING CONTINUE:"))
                    {
                        HandleContinue();
                        return true;
                    }

                    OnBlenderOutput?.Invoke(line);
                }
                catch { }
                return false;
            }
        }


        /// <summary>
        /// Contains the rendering status (tiles etc)
        /// </summary>
        public class Status
        {
            public int Time { get; set; }
            public int TimeRemaining { get; set; }
            public int TilesFinish { get; set; }
            public int TilesTotal { get; set; }
            public string Phase { get; set; }
        }

        public class Result
        {
            public string[] Results { get; set; }
            public string[] Exceptions { get; set; }
        }

        [GeneratedRegex("Fra:.*Time:(.*?)\\|.*?Remaining:(.*?)\\|.*?Rendered(.*?)\\/(.*?)Tiles")]
        private static partial Regex BlenderRegex();
        [GeneratedRegex("Fra:.*Time:(.*?)\\|.*?Remaining:(.*?)\\|.*?Sample(.*?)\\/([0-9]*)")]
        private static partial Regex BlenderRegex2();
    }
}


