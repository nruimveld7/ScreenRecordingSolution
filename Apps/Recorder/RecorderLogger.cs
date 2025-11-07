using System;
using System.Diagnostics;
using System.IO;

namespace ScreenRecorderTray {
    public static class RecorderLogger {
        private static readonly string LogDir = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Logs");

        public static void Log(string msg) {
            var line = string.Format("{0} - {1}", DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"), msg);
            try {
                Directory.CreateDirectory(LogDir);
                var path = Path.Combine(LogDir, DateTime.Now.ToString("ddMMyyyy") + ".log");
                File.AppendAllText(path, line + Environment.NewLine);
            } catch {
                // ignore
            }
            Debug.WriteLine(line);
        }

        public static void SafeLog(string msg) {
            try {
                Log(msg);
            } catch {
                // ignore
            }
        }
        public static void OpenLogFolder() {
            try {
                Process.Start("explorer.exe", LogDir);
            } catch {
                // ignore
            }
        }
    }
}
