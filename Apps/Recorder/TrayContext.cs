using System;
using System.Drawing;
using System.Windows.Forms;

namespace ScreenRecorderTray
{
    public sealed class TrayContext : ApplicationContext
    {
        private readonly NotifyIcon m_tray;
        private readonly RecorderManager m_rec;

        public TrayContext()
        {
            var appIcon = Icon.ExtractAssociatedIcon(Application.ExecutablePath) ?? SystemIcons.Application;

            m_tray = new NotifyIcon
            {
                Text = "Screen Recorder",
                Icon = appIcon,
                Visible = true
            };

            var menu = new ContextMenuStrip();
            menu.Items.Add("Open Logs", null, (_, __) => RecorderLogger.OpenLogFolder());
            menu.Items.Add("Restart", null, async (_, __) => await m_rec.RestartAsync());
            menu.Items.Add("Exit", null, (_, __) => ExitThread());

            m_tray.ContextMenuStrip = menu;

            m_rec = new RecorderManager(m_tray);
            _ = m_rec.StartAsync(); // fire-and-forget
        }

        protected override void ExitThreadCore()
        {
            m_rec?.Dispose();
            m_tray.Visible = false;
            m_tray.Dispose();
            base.ExitThreadCore();
        }
    }
}
