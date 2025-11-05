using System;
using System.Security.Principal;
using System.Threading;
using System.Windows.Forms;

namespace ScreenRecorderTray
{
    internal static class Program
    {
        private static Mutex _singleInstanceMutex;

        [STAThread]
        static void Main()
        {
            try
            {
                // One instance per user across all sessions: Global\ mutex keyed by user SID.
                string sid = "unknown";
                try
                {
                    var wi = WindowsIdentity.GetCurrent();
                    if (wi != null && wi.User != null) sid = wi.User.Value;
                    else sid = Environment.UserName; // fallback
                }
                catch
                {
                    sid = Environment.UserName;
                }

                string mutexName = @"Global\ScreenRecorder_" + sid;
                bool createdNew;
                _singleInstanceMutex = new Mutex(true, mutexName, out createdNew);

                if (!createdNew)
                {
                    // Another instance for this user is already running on this machine.
                    RecorderLogger.SafeLog("Another instance already running for this user (mutex " + mutexName + "). Exiting.");
                    return;
                }
            }
            catch (Exception ex)
            {
                // If mutex creation fails for any reason, fail closed (exit) to avoid duplicate recording.
                RecorderLogger.SafeLog("Failed to create single-instance mutex: " + ex);
                return;
            }

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            AppDomain.CurrentDomain.UnhandledException += (_, e) =>
                RecorderLogger.SafeLog("FATAL: " + e.ExceptionObject);

            Application.Run(new TrayContext());

            // Mutex is released when process exits; keep the object alive until here.
            try { if (_singleInstanceMutex != null) _singleInstanceMutex.ReleaseMutex(); } catch { }
        }
    }
}
