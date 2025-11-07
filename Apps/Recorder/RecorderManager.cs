using Microsoft.Win32;
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace ScreenRecorderTray {
    public sealed class RecorderManager : IDisposable {
        private static readonly Regex _durationRe = new Regex(@"^\s*(\d+)\s*([smhdSMHD]?)\s*$", RegexOptions.Compiled);
        private readonly NotifyIcon _tray;
        private readonly FileSystemWatcher _iniWatcher;
        private Process _ffmpeg;
        private WinJob _job; // ensures child is killed when app exits
        private readonly object _gate = new object();
        private CancellationTokenSource _runCts;

        private string _baseDir;
        private string _iniPath;
        private RecorderConfig _cfg;

        // timers
        private System.Threading.Timer _debounce;
        private System.Threading.Timer _housekeep;
        private System.Threading.Timer _guard;
        private System.Threading.Timer _restartTimer;
        private volatile bool _isRestarting;

        private string _currentOutDir;

        public RecorderManager(NotifyIcon tray) {
            _tray = tray;
            _baseDir = AppDomain.CurrentDomain.BaseDirectory;
            _iniPath = Path.Combine(_baseDir, "recorder.ini");
            _iniWatcher = new FileSystemWatcher(Path.GetDirectoryName(_iniPath) ?? ".", Path.GetFileName(_iniPath) ?? "recorder.ini");
            _iniWatcher.NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.Size | NotifyFilters.FileName;
            _iniWatcher.Changed += delegate {
                DebouncedRestart();
            };
            _iniWatcher.Renamed += delegate {
                DebouncedRestart();
            };
            _iniWatcher.EnableRaisingEvents = true;
            SystemEvents.DisplaySettingsChanged += delegate {
                DebouncedRestart();
            };
            AppDomain.CurrentDomain.ProcessExit += delegate {
                try {
                    ForceKillFfmpegTree();
                } catch {
                    // ignore
                }
            };
        }

        public Task StartAsync() {
            return RestartAsync();
        }

        public async Task RestartAsync() {
            if(_isRestarting) {
                return;
            }
            _isRestarting = true;
            try {
                RecorderLogger.Log("Restart requested");
                await StopInternalAsync();
                LoadConfig();
                StartFfmpeg();
            } catch(Exception ex) {
                RecorderLogger.Log("Restart failed: " + ex);
                _tray.ShowBalloonTip(1500, "Screen Recorder", "Restart failed—check logs.", ToolTipIcon.Error);
            } finally {
                _isRestarting = false;
            }
        }

        private void DebouncedRestart() {
            if(_debounce != null) {
                _debounce.Dispose();
            }
            _debounce = new System.Threading.Timer(async _ => await RestartAsync(), null, 500, Timeout.Infinite);
        }

        private void LoadConfig() {
            if(!File.Exists(_iniPath)) {
                throw new FileNotFoundException("Missing recorder.ini", _iniPath);
            }
            var ini = SimpleIni.Load(_iniPath);
            var s = ini["recorder"];
            _cfg = new RecorderConfig();
            _cfg.RecordDir = ResolvePath(s.Get("record_dir", "./recordings"));
            _cfg.OutputPattern = s.Get("output_pattern", "desktop_%Y%m%d_%H%M%S.mkv");
            _cfg.RecordSubdirTemplate = s.Get("record_subdir_template", "{username}/s{session}");
            _cfg.SegmentSeconds = s.GetInt("segment_seconds", 3600, 1);
            _cfg.Fps = s.GetInt("fps", 12, 1);
            _cfg.KeepLocal = s.GetInt("keep_local", 2, 0);
            _cfg.UploadUrl = NormalizeUploadUrl(s.Get("upload_url", ""));
            _cfg.UploadToken = s.Get("upload_token", "");
            var sysNameRaw = s.Get("system_name", "").Trim();
            _cfg.SystemName = string.IsNullOrEmpty(sysNameRaw) ? Environment.MachineName : sysNameRaw;
            _cfg.FfmpegPath = ResolvePath(s.Get("ffmpeg_path", "./ffmpeg.exe"));
            _cfg.RetryDelaySeconds = s.GetInt("retry_delay_seconds", 180, 1);
            _cfg.Encoder = s.Get("encoder", "auto").ToLowerInvariant();
            _cfg.Libx264Crf = s.GetInt("libx264_crf", 28, 0);
            _cfg.ProbeSeconds = s.GetInt("probe_seconds", 3, 1);
            _cfg.Verbose = s.GetBool("verbose", false);
            _cfg.MaxFailedUploadAge = ParseDuration(s.Get("max_failed_upload_age", ""), TimeSpan.Zero);
        }

        private string ResolvePath(string p) {
            if(Path.IsPathRooted(p)) {
                return p;
            }
            return Path.GetFullPath(Path.Combine(_baseDir, p));
        }

        private static string NormalizeUploadUrl(string u) {
            var t = (u ?? "").Trim();
            var lower = t.ToLowerInvariant();
            if(lower == "" || lower == "skip" || lower == "none" || lower == "disabled" || lower == "false") {
                return "";
            }
            return t;
        }

        private static TimeSpan ParseDuration(string raw, TimeSpan defaultValue) {
            if(string.IsNullOrWhiteSpace(raw)) {
                return defaultValue;
            }
            var m = _durationRe.Match(raw);
            if(!m.Success) {
                return defaultValue;
            }
            int value;
            if(!int.TryParse(m.Groups[1].Value, out value)) {
                return defaultValue;
            }
            if(value < 0) {
                value = 0;
            }
            var unit = m.Groups[2].Value.ToLowerInvariant();
            if(unit == "m") {
                return TimeSpan.FromMinutes(value);
            }
            if(unit == "h") {
                return TimeSpan.FromHours(value);
            }
            if(unit == "d") {
                return TimeSpan.FromDays(value);
            }
            return TimeSpan.FromSeconds(value);
        }

        private static string Q(string s) {
            if(s == null) {
                s = string.Empty;
            }
            return "\"" + s.Replace("\"", "\\\"") + "\"";
        }

        private void StartFfmpeg() {
            var identity = Identity.BuildDict();
            var subdir = Template.Apply(_cfg.RecordSubdirTemplate, identity, "record_subdir_template");
            var outDir = string.IsNullOrWhiteSpace(subdir) ? _cfg.RecordDir : Path.Combine(_cfg.RecordDir, subdir);
            Directory.CreateDirectory(outDir);
            _currentOutDir = outDir;
            var outPattern = Template.Apply(_cfg.OutputPattern, identity, "output_pattern");
            if(string.IsNullOrWhiteSpace(outPattern)) {
                outPattern = "desktop_%Y%m%d_%H%M%S.mkv";
            }
            var outPath = Path.Combine(outDir, outPattern);
            var screens = Screen.AllScreens.OrderBy(s => s.Bounds.Left).ThenBy(s => s.Bounds.Top).ToArray();
            if(screens.Length == 0) {
                throw new InvalidOperationException("No monitors detected.");
            }
            var psi = new ProcessStartInfo();
            psi.FileName = _cfg.FfmpegPath;
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            psi.RedirectStandardInput = true;
            var args = new List<string>();
            args.AddRange(new[] { "-hide_banner", "-loglevel", "warning", "-rtbufsize", "256M" });
            for(int i = 0; i < screens.Length; i++) {
                var s = screens[i];
                int w = s.Bounds.Width;
                int h = s.Bounds.Height;
                int x = s.Bounds.Left;
                int y = s.Bounds.Top;
                args.AddRange(new[] {
                    "-thread_queue_size", "1024",
                    "-probesize", "64M",
                    "-f", "gdigrab",
                    "-framerate", _cfg.Fps.ToString(),
                    "-draw_mouse", "1",
                    "-video_size", w.ToString() + "x" + h.ToString(),
                    "-offset_x", x.ToString(),
                    "-offset_y", y.ToString(),
                    "-i", "desktop"
                });
            }
            // Build filters depending on number of inputs
            string filter;
            if(screens.Length == 1) {
                // Single monitor: no xstack; ensure even dimensions, fps, format
                filter = "[0:v]fps=" + _cfg.Fps + ",format=yuv420p" + ",scale=trunc(iw/2)*2:trunc(ih/2)*2" + "[final]";
            } else {
                int minX = screens.Min(s => s.Bounds.Left);
                int minY = screens.Min(s => s.Bounds.Top);
                var layoutParts = new List<string>();
                for(int i = 0; i < screens.Length; i++) {
                    var s = screens[i];
                    layoutParts.Add((s.Bounds.Left - minX).ToString() + "_" + (s.Bounds.Top - minY).ToString());
                }
                string layout = string.Join("|", layoutParts);

                string inputs = "";
                for(int i = 0; i < screens.Length; i++) {
                    inputs += "[" + i + ":v]";
                }
                filter = inputs + "xstack=inputs=" + screens.Length + ":layout=" + layout + ":fill=black[stack];" + "[stack]pad=ceil(iw/2)*2:ceil(ih/2)*2[stackp];" + "[stackp]fps=" + _cfg.Fps + "[stackf];" + "[stackf]format=yuv420p[final]";
            }
            args.AddRange(new[] { "-filter_complex", filter });
            if(_cfg.Encoder == "libx264") {
                args.AddRange(new[] { "-c:v", "libx264", "-preset", "veryfast", "-crf", _cfg.Libx264Crf.ToString(), "-pix_fmt", "yuv420p" });
            } else if(_cfg.Encoder == "h264_nvenc") {
                args.AddRange(new[] { "-c:v", "h264_nvenc", "-preset", "fast", "-b:v", "4M", "-maxrate", "5M", "-bufsize", "10M", "-pix_fmt", "yuv420p" });
            } else if(_cfg.Encoder == "h264_qsv") {
                args.AddRange(new[] { "-c:v", "h264_qsv", "-preset", "veryfast", "-b:v", "4M", "-pix_fmt", "yuv420p" });
            } else {
                args.AddRange(new[] { "-c:v", "libx264", "-preset", "veryfast", "-crf", _cfg.Libx264Crf.ToString(), "-pix_fmt", "yuv420p" });
            }
            int gop = Math.Max(1, _cfg.Fps * _cfg.SegmentSeconds);
            args.AddRange(new[] {
                "-g", gop.ToString(),
                "-force_key_frames", "expr:gte(t,n_forced*" + _cfg.SegmentSeconds + ")",
                "-map", "[final]",
                "-f", "segment",
                "-segment_time", _cfg.SegmentSeconds.ToString(),
                "-segment_atclocktime", "1",
                "-strftime", "1",
                "-reset_timestamps", "1",
                Q(outPath)
            });
            psi.Arguments = string.Join(" ", args.ToArray());
            RecorderLogger.Log("Starting ffmpeg: " + psi.FileName + " " + psi.Arguments);
            lock(_gate) {
                _runCts = new CancellationTokenSource();
                _ffmpeg = new Process();
                _ffmpeg.StartInfo = psi;
                _ffmpeg.EnableRaisingEvents = true;
                _ffmpeg.OutputDataReceived += delegate (object sender, DataReceivedEventArgs e) {
                    if(!string.IsNullOrEmpty(e.Data)) {
                        RecorderLogger.Log("[ffmpeg] " + e.Data);
                    }
                };
                _ffmpeg.ErrorDataReceived += delegate (object sender, DataReceivedEventArgs e) {
                    if(!string.IsNullOrEmpty(e.Data)) {
                        RecorderLogger.Log("[ffmpeg] " + e.Data);
                    }
                };
                _ffmpeg.Exited += delegate {
                    RecorderLogger.Log("ffmpeg exited; scheduling restart");
                    ScheduleDelayedRestart();
                };
                _ffmpeg.Start();
                _ffmpeg.BeginOutputReadLine();
                _ffmpeg.BeginErrorReadLine();
                _job = new WinJob();
                try {
                    if(!_job.Assign(_ffmpeg)) {
                        RecorderLogger.Log("Job assign skipped: process already in a job or access denied.");
                    }
                } catch(Exception ex) {
                    RecorderLogger.Log("Job assign failed: " + ex.Message);
                }
            }
            _tray.Text = "Screen Recorder (recording)";
            if(_housekeep != null) {
                _housekeep.Dispose();
            }
            _housekeep = new System.Threading.Timer(_ => { try { Housekeep(); } catch { } }, null, 60000, 60000);
            if(_guard != null) {
                _guard.Dispose();
            }
            int guardPeriod = Math.Max(5, _cfg.RetryDelaySeconds);
            _guard = new System.Threading.Timer(_ => {
                try {
                    Process p;
                    lock(_gate) {
                        p = _ffmpeg;
                    }
                    if(p == null || p.HasExited) {
                        ScheduleDelayedRestart();
                    }
                } catch {
                    // ignore
                }
            }, null, guardPeriod * 1000, guardPeriod * 1000);
        }

        private void ScheduleDelayedRestart() {
            try {
                if(_isRestarting) {
                    return;
                }
                int delayMs = Math.Max(1, _cfg != null ? _cfg.RetryDelaySeconds : 30) * 1000;
                if(_restartTimer != null) {
                    _restartTimer.Dispose();
                }
                _restartTimer = new System.Threading.Timer(async _ => await RestartAsync(), null, delayMs, Timeout.Infinite);
            } catch {
                // ignore
            }
        }

        private void Housekeep() {
            if(string.IsNullOrEmpty(_currentOutDir) || !Directory.Exists(_currentOutDir)) {
                return;
            }
            string ext = Path.GetExtension(_cfg.OutputPattern);
            if(string.IsNullOrEmpty(ext)) {
                ext = ".mkv";
            }
            string[] files = Directory.GetFiles(_currentOutDir, "*" + ext);
            if(files == null || files.Length == 0) {
                return;
            }
            var ordered = files.Select(f => new FileInfo(f)).OrderByDescending(fi => fi.LastWriteTimeUtc).ToList();
            var enforceMaxAge = _cfg.MaxFailedUploadAge > TimeSpan.Zero;
            var nowUtc = DateTime.UtcNow;
            for(int i = Math.Max(_cfg.KeepLocal, 1); i < ordered.Count; i++) {
                var fi = ordered[i];
                if(!IsFileStable(fi.FullName)) {
                    continue;
                }
                if(enforceMaxAge && (nowUtc - fi.LastWriteTimeUtc) > _cfg.MaxFailedUploadAge) {
                    RecorderLogger.Log("Deleting stale recording (over max_failed_upload_age): " + fi.Name);
                    TryDelete(fi.FullName);
                    continue;
                }
                if(!string.IsNullOrEmpty(_cfg.UploadUrl)) {
                    try {
                        var recordingUser = ResolveRecordingUserLabel(fi.FullName);
                        UploadFile(fi.FullName, _cfg.UploadUrl, _cfg.UploadToken, _cfg.SystemName, recordingUser);
                        RecorderLogger.Log("Uploaded: " + fi.Name);
                        TryDelete(fi.FullName);
                    } catch(Exception ex) {
                        RecorderLogger.Log("Upload failed, keeping file: " + fi.Name + " :: " + ex.Message);
                    }
                } else {
                    TryDelete(fi.FullName);
                }
            }
        }

        private static bool IsFileStable(string path) {
            try {
                using(var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.None)) {
                    return true;
                }
            } catch {
                return false;
            }
        }

        private static void TryDelete(string path) {
            try {
                File.Delete(path);
            } catch(Exception ex) {
                RecorderLogger.Log("Delete failed: " + path + " :: " + ex.Message);
            }
        }

        private string ResolveRecordingUserLabel(string filePath) {
            try {
                var directory = Path.GetDirectoryName(filePath);
                if(string.IsNullOrEmpty(directory)) {
                    return string.Empty;
                }
                var fullDir = Path.GetFullPath(directory);
                var recordRoot = string.IsNullOrEmpty(_cfg.RecordDir) ? string.Empty : Path.GetFullPath(_cfg.RecordDir);
                if(!string.IsNullOrEmpty(recordRoot) && fullDir.StartsWith(recordRoot, StringComparison.OrdinalIgnoreCase)) {
                    var relative = fullDir.Substring(recordRoot.Length).Trim('/', '\\');
                    if(!string.IsNullOrEmpty(relative)) {
                        var parts = relative.Split(new[] { Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar }, StringSplitOptions.RemoveEmptyEntries);
                        if(parts.Length > 0) {
                            return parts[parts.Length - 1];
                        }
                    }
                }
                return Path.GetFileName(fullDir) ?? string.Empty;
            } catch {
                return string.Empty;
            }
        }

        private static void UploadFile(string path, string url, string token, string systemName, string recordingUser) {
            using(var client = new HttpClient()) {
                if(!string.IsNullOrEmpty(token)) {
                    client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);
                }
                using(var content = new MultipartFormDataContent()) {
                    if(!string.IsNullOrEmpty(systemName)) {
                        content.Add(new StringContent(systemName, Encoding.UTF8), "systemName");
                    }
                    if(!string.IsNullOrEmpty(recordingUser)) {
                        content.Add(new StringContent(recordingUser, Encoding.UTF8), "recordingUser");
                    }
                    using(var fileStream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read)) {
                        var fileContent = new StreamContent(fileStream);
                        fileContent.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
                        content.Add(fileContent, "file", Path.GetFileName(path));
                        using(var response = client.PostAsync(url, content).GetAwaiter().GetResult()) {
                            response.EnsureSuccessStatusCode();
                        }
                    }
                }
            }
        }

        private Task StopInternalAsync() {
            if(_housekeep != null) {
                try {
                    _housekeep.Dispose();
                } catch {
                    // ignore
                }
                _housekeep = null;
            }
            if(_guard != null) {
                try {
                    _guard.Dispose();
                } catch {
                    // ignore
                }
                _guard = null;
            }
            if(_restartTimer != null) {
                try {
                    _restartTimer.Dispose();
                } catch {
                    // ignore
                }
                _restartTimer = null;
            }
            Process p = null;
            WinJob job = null;
            lock(_gate) {
                if(_runCts != null) {
                    _runCts.Cancel();
                    _runCts.Dispose();
                    _runCts = null;
                }
                p = _ffmpeg;
                job = _job;
                _ffmpeg = null;
                _job = null;
            }
            if(p != null) {
                try {
                    if(!p.HasExited) {
                        try {
                            if(p.StartInfo.RedirectStandardInput) {
                                p.StandardInput.WriteLine("q");
                                p.StandardInput.Flush();
                            }
                        } catch {
                            // ignore
                        }
                        if(!p.WaitForExit(2000)) {
                            try {
                                if(job != null) {
                                    job.Dispose();
                                }
                            } catch {
                                // ignore
                            }
                            if(!p.WaitForExit(1500)) {
                                try {
                                    var tk = Process.Start(new ProcessStartInfo {
                                        FileName = "taskkill.exe",
                                        Arguments = "/PID " + p.Id + " /T /F",
                                        CreateNoWindow = true,
                                        UseShellExecute = false
                                    });
                                    if(tk != null) {
                                        tk.WaitForExit(2000);
                                    }
                                } catch {
                                    // ignore
                                }
                                try {
                                    if(!p.HasExited)
                                        p.Kill();
                                } catch {
                                    // ignore
                                }
                            }
                        }
                    }
                } finally {
                    try {
                        p.Dispose();
                    } catch {
                        // ignore
                    }
                }
            }
            _tray.Text = "Screen Recorder (idle)";
            return Task.CompletedTask;
        }


        private void ForceKillFfmpegTree() {
            Process p = _ffmpeg;
            if(p == null) {
                return;
            }
            try {
                if(!p.HasExited) {
                    try {
                        if(_job != null) {
                            _job.Dispose();
                        }
                    } catch {
                        // ignore
                    }
                    try {
                        if(!p.HasExited) {
                            p.Kill();
                        }
                    } catch {
                        // ignore
                    }
                }
            } catch {
                // ignore
            }
        }

        public void Dispose() {
            _iniWatcher.Dispose();
            try {
                StopInternalAsync().Wait(2000);
            } catch { }
            if(_job != null) {
                try {
                    _job.Dispose();
                } catch {
                    // ignore
                }
                _job = null;
            }
            if(_debounce != null) {
                try {
                    _debounce.Dispose();
                } catch {
                    // ignore
                }
                _debounce = null;
            }
            if(_housekeep != null) {
                try {
                    _housekeep.Dispose();
                } catch {
                    // ignore
                }
                _housekeep = null;
            }
            if(_guard != null) {
                try {
                    _guard.Dispose();
                } catch {
                    // ignore
                }
                _guard = null;
            }
            if(_restartTimer != null) {
                try {
                    _restartTimer.Dispose();
                } catch {
                    // ignore
                }
                _restartTimer = null;
            }
        }
    }

    internal sealed class RecorderConfig {
        public string RecordDir;
        public string OutputPattern;
        public string RecordSubdirTemplate;
        public string UploadUrl;
        public string UploadToken;
        public string SystemName;
        public string FfmpegPath;
        public string Encoder;
        public int SegmentSeconds;
        public int Fps;
        public int KeepLocal;
        public int RetryDelaySeconds;
        public int Libx264Crf;
        public int ProbeSeconds;
        public TimeSpan MaxFailedUploadAge;
        public bool Verbose;
    }

    internal static class Identity {
        public static Dictionary<string, string> BuildDict() {
            var dict = new Dictionary<string, string>();
            dict["username"] = San(Environment.UserName);
            dict["host"] = San(Environment.MachineName);
            try {
                dict["session"] = San(Process.GetCurrentProcess().SessionId.ToString());
            } catch { dict["session"] = "0"; }
            return dict;
        }

        private static string San(string v) {
            if(v == null) {
                v = "unknown";
            }
            foreach(var c in Path.GetInvalidFileNameChars()) {
                v = v.Replace(c, '_');
            }
            return v;
        }
    }

    internal static class Template {
        public static string Apply(string tpl, Dictionary<string, string> vals, string label) {
            try {
                return tpl.Replace("{username}", vals["username"]).Replace("{session}", vals["session"]).Replace("{host}", vals["host"]);
            } catch {
                throw new InvalidOperationException("Bad token in " + label + ". Allowed: {username}, {session}, {host}");
            }
        }
    }
}
