using System;
using System.Collections.Generic;
using System.Threading.Tasks;

namespace LogicReinc.BlendFarm
{
    /// <summary>
    /// Global exception logging system that captures all exceptions in one place
    /// </summary>
    public static class ExceptionLogger
    {
        private static readonly object _lockObj = new object();
        private static HashSet<string> _loggedExceptions = new();

        public static void Configure()
        {
            AppDomain.CurrentDomain.UnhandledException += (s, e) =>
            {
                LogException("UNHANDLED EXCEPTION (AppDomain)", (Exception)e.ExceptionObject);
            };

            TaskScheduler.UnobservedTaskException += (s, e) =>
            {
                LogException("UNOBSERVED TASK EXCEPTION", e.Exception);
                e.SetObserved();
            };

            AppDomain.CurrentDomain.FirstChanceException += (s, e) =>
            {
                if (ShouldLogFirstChance(e.Exception))
                {
                    LogException("FIRST CHANCE EXCEPTION", e.Exception, isFirstChance: true);
                }
            };
        }


        public static void LogException(string title, Exception ex, bool isFirstChance = false)
        {
            string exceptionKey = $"{ex.GetType().FullName}:{ex.Message}:{ex.StackTrace}";

            lock (_lockObj)
            {
                if (isFirstChance && _loggedExceptions.Contains(exceptionKey))
                    return;

                _loggedExceptions.Add(exceptionKey);
            }

            Console.WriteLine($"\n{'='} {title} {'='}\n");
            LogExceptionDetails(ex, depth: 0);
            Console.WriteLine();
        }

        private static void LogExceptionDetails(Exception ex, int depth = 0)
        {
            string indent = new string(' ', depth * 2);
            Console.WriteLine($"{indent}[{ex.GetType().FullName}]");
            Console.WriteLine($"{indent}Message: {ex.Message}");

            if (!string.IsNullOrEmpty(ex.StackTrace))
            {
                Console.WriteLine($"{indent}StackTrace:");
                foreach (string line in ex.StackTrace.Split('\n'))
                {
                    if (!string.IsNullOrWhiteSpace(line))
                        Console.WriteLine($"{indent}  {line.Trim()}");
                }
            }

            if (ex.InnerException != null)
            {
                Console.WriteLine($"{indent}InnerException:");
                LogExceptionDetails(ex.InnerException, depth + 1);
            }
        }

        private static bool ShouldLogFirstChance(Exception ex)
        {
            string typeName = ex.GetType().FullName;

            if (typeName == null)
                return false;

            var ignoredNamespaces = new[]
            {
                "System.Threading.SynchronizationLockException",
                "System.Reflection.TargetInvocationException",
            };

            foreach (var ignoredType in ignoredNamespaces)
            {
                if (typeName.Contains(ignoredType))
                    return false;
            }

            return true;
        }
    }
}
