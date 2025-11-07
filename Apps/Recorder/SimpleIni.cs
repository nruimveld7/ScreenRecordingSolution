using System;
using System.Collections.Generic;
using System.IO;

namespace ScreenRecorderTray {
    public sealed class SimpleIni {
        private readonly Dictionary<string, Dictionary<string, string>> _d =
            new Dictionary<string, Dictionary<string, string>>(StringComparer.OrdinalIgnoreCase);

        public Dictionary<string, string> this[string section] {
            get {
                Dictionary<string, string> s;
                if(_d.TryGetValue(section, out s))
                    return s;
                s = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                _d[section] = s;
                return s;
            }
        }

        public static SimpleIni Load(string path) {
            var ini = new SimpleIni();
            var current = ini["recorder"]; // default section
            var lines = File.ReadAllLines(path);
            foreach(var raw in lines) {
                var line = (raw ?? string.Empty).Trim();
                if(line.Length == 0 || line.StartsWith(";"))
                    continue;

                if(line.StartsWith("[") && line.EndsWith("]") && line.Length >= 2) {
                    var name = line.Substring(1, line.Length - 2);
                    current = ini[name];
                    continue;
                }

                var idx = line.IndexOf('=');
                if(idx <= 0)
                    continue;
                var key = line.Substring(0, idx).Trim();
                var val = line.Substring(idx + 1).Trim();
                current[key] = val;
            }
            return ini;
        }
    }

    public static class IniSecExtensions {
        public static string Get(this Dictionary<string, string> s, string key, string defval) {
            string v;
            return s.TryGetValue(key, out v) ? v : defval;
        }

        public static int GetInt(this Dictionary<string, string> s, string key, int defval, int min) {
            string v;
            int i;
            if(!s.TryGetValue(key, out v) || !int.TryParse(v, out i))
                i = defval;
            if(i < min)
                i = min;
            return i;
        }

        public static bool GetBool(this Dictionary<string, string> s, string key, bool defval) {
            string v;
            if(!s.TryGetValue(key, out v))
                return defval;
            return string.Equals(v, "1", StringComparison.OrdinalIgnoreCase) ||
                   string.Equals(v, "true", StringComparison.OrdinalIgnoreCase);
        }
    }
}
