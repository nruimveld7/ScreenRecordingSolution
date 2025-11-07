using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace ScreenRecorderTray {
    /// <summary>
    /// Windows Job Object wrapper with KILL_ON_JOB_CLOSE.
    /// Uses OpenProcess with required rights and skips assignment if process is already in a job (common on Win7 in some contexts).
    /// </summary>
    public sealed class WinJob : IDisposable {
        private IntPtr m_handle;

        public WinJob() {
            m_handle = CreateJobObject(IntPtr.Zero, null);
            if(m_handle == IntPtr.Zero)
                throw new Win32Exception();

            var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;

            int length = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
            IntPtr ptr = Marshal.AllocHGlobal(length);
            try {
                Marshal.StructureToPtr(info, ptr, false);
                if(!SetInformationJobObject(m_handle, JobObjectInfoType.ExtendedLimitInformation, ptr, (uint)length))
                    throw new Win32Exception();
            } finally { Marshal.FreeHGlobal(ptr); }
        }

        public bool Assign(Process process) {
            if(process == null)
                throw new ArgumentNullException("process");
            return Assign(process.Id);
        }

        public bool Assign(int pid) {
            IntPtr processHandle = IntPtr.Zero;
            try {
                processHandle = OpenProcess(PROCESS_SET_QUOTA | PROCESS_TERMINATE | PROCESS_QUERY_INFORMATION | PROCESS_DUP_HANDLE | SYNCHRONIZE, false, pid);
                if(processHandle == IntPtr.Zero) {
                    throw new Win32Exception();
                }

                bool childInJob;
                if(!IsProcessInJob(processHandle, IntPtr.Zero, out childInJob)) {
                    throw new Win32Exception();
                }

                if(childInJob) {
                    // Cannot assign a process that's already in a job on Win7.
                    return false;
                }

                if(!AssignProcessToJobObject(m_handle, processHandle)) {
                    int error = Marshal.GetLastWin32Error();
                    if(error == 5 /*ACCESS_DENIED*/) {
                        return false;
                    }
                    throw new Win32Exception(error);
                }
                return true;
            } finally {
                if(processHandle != IntPtr.Zero)
                    CloseHandle(processHandle);
            }
        }

        public void Dispose() {
            if(m_handle != IntPtr.Zero) {
                CloseHandle(m_handle);
                m_handle = IntPtr.Zero;
            }
        }

        // P/Invoke & constants

        private const int JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;

        private const uint PROCESS_TERMINATE = 0x0001;
        private const uint PROCESS_SET_QUOTA = 0x0100;
        private const uint PROCESS_DUP_HANDLE = 0x0040;
        private const uint PROCESS_QUERY_INFORMATION = 0x0400;
        private const uint SYNCHRONIZE = 0x00100000;

        private enum JobObjectInfoType {
            ExtendedLimitInformation = 9
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct IO_COUNTERS {
            public ulong ReadOperationCount;
            public ulong WriteOperationCount;
            public ulong OtherOperationCount;
            public ulong ReadTransferCount;
            public ulong WriteTransferCount;
            public ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public int LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public int ActiveProcessLimit;
            public long Affinity;
            public int PriorityClass;
            public int SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
            public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
            public IO_COUNTERS IoInfo;
            public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed;
            public UIntPtr PeakJobMemoryUsed;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr CreateJobObject(IntPtr lpJobAttributes, string lpName);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetInformationJobObject(IntPtr hJob, JobObjectInfoType infoType, IntPtr lpJobObjectInfo, uint cbJobObjectInfoLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr hObject);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool IsProcessInJob(IntPtr processHandle, IntPtr jobHandle, out bool result);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, int dwProcessId);
    }
}
