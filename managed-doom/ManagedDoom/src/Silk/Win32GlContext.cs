using System;
using System.Runtime.InteropServices;
using Silk.NET.Core.Contexts;

namespace ManagedDoom.Silk
{
    public sealed class Win32GlContext : INativeContext
    {
        [DllImport("opengl32.dll", SetLastError = true)]
        private static extern IntPtr wglGetProcAddress(string lpszProc);

        private readonly IntPtr _opengl32;

        public Win32GlContext()
        {
            _opengl32 = NativeLibrary.Load("opengl32.dll");
        }

        public nint GetProcAddress(string proc, int? slot = null)
        {
            var addr = wglGetProcAddress(proc);
            if (addr != IntPtr.Zero && addr != (IntPtr)1 && addr != (IntPtr)2 && addr != (IntPtr)(-1))
                return addr;

            if (NativeLibrary.TryGetExport(_opengl32, proc, out var export))
                return export;

            return IntPtr.Zero;
        }

        public bool TryGetProcAddress(string proc, out nint addr, int? slot = null)
        {
            addr = GetProcAddress(proc, slot);
            return addr != IntPtr.Zero;
        }

        public void Dispose()
        {
        }
    }
}
