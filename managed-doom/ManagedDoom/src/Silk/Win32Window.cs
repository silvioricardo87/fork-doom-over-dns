using System;
using System.Runtime.InteropServices;

namespace ManagedDoom.Silk
{
    public sealed class Win32Window : IDisposable
    {
        // ── P/Invoke delegates ──

        private delegate IntPtr WndProcDelegate(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

        // ── P/Invoke structs ──

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct WNDCLASSEXW
        {
            public uint cbSize;
            public uint style;
            public WndProcDelegate lpfnWndProc;
            public int cbClsExtra;
            public int cbWndExtra;
            public IntPtr hInstance;
            public IntPtr hIcon;
            public IntPtr hCursor;
            public IntPtr hbrBackground;
            public string lpszMenuName;
            public string lpszClassName;
            public IntPtr hIconSm;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct MSG
        {
            public IntPtr hwnd;
            public uint message;
            public IntPtr wParam;
            public IntPtr lParam;
            public uint time;
            public int ptX;
            public int ptY;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct POINT
        {
            public int X;
            public int Y;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct RECT
        {
            public int Left, Top, Right, Bottom;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct PIXELFORMATDESCRIPTOR
        {
            public ushort nSize;
            public ushort nVersion;
            public uint dwFlags;
            public byte iPixelType;
            public byte cColorBits;
            public byte cRedBits, cRedShift;
            public byte cGreenBits, cGreenShift;
            public byte cBlueBits, cBlueShift;
            public byte cAlphaBits, cAlphaShift;
            public byte cAccumBits;
            public byte cAccumRedBits, cAccumGreenBits, cAccumBlueBits, cAccumAlphaBits;
            public byte cDepthBits;
            public byte cStencilBits;
            public byte cAuxBuffers;
            public byte iLayerType;
            public byte bReserved;
            public uint dwLayerMask, dwVisibleMask, dwDamageMask;
        }

        // ── P/Invoke: user32.dll ──

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern ushort RegisterClassExW(ref WNDCLASSEXW lpwcx);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr CreateWindowExW(
            uint dwExStyle, string lpClassName, string lpWindowName, uint dwStyle,
            int x, int y, int nWidth, int nHeight,
            IntPtr hWndParent, IntPtr hMenu, IntPtr hInstance, IntPtr lpParam);

        [DllImport("user32.dll")]
        private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

        [DllImport("user32.dll")]
        private static extern bool UpdateWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        private static extern bool PeekMessageW(out MSG lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax, uint wRemoveMsg);

        [DllImport("user32.dll")]
        private static extern bool TranslateMessage(ref MSG lpMsg);

        [DllImport("user32.dll")]
        private static extern IntPtr DispatchMessageW(ref MSG lpMsg);

        [DllImport("user32.dll")]
        private static extern IntPtr DefWindowProcW(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern bool DestroyWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        private static extern void PostQuitMessage(int nExitCode);

        [DllImport("user32.dll")]
        private static extern IntPtr LoadCursorW(IntPtr hInstance, IntPtr lpCursorName);

        [DllImport("user32.dll")]
        private static extern int ShowCursor(bool bShow);

        [DllImport("user32.dll")]
        private static extern bool GetCursorPos(out POINT lpPoint);

        [DllImport("user32.dll")]
        private static extern bool SetCursorPos(int x, int y);

        [DllImport("user32.dll")]
        private static extern bool ClipCursor(IntPtr lpRect);

        [DllImport("user32.dll")]
        private static extern bool ClipCursor(ref RECT lpRect);

        [DllImport("user32.dll")]
        private static extern bool GetClientRect(IntPtr hWnd, out RECT lpRect);

        [DllImport("user32.dll")]
        private static extern bool ClientToScreen(IntPtr hWnd, ref POINT lpPoint);

        [DllImport("user32.dll")]
        private static extern bool ScreenToClient(IntPtr hWnd, ref POINT lpPoint);

        [DllImport("user32.dll")]
        private static extern int GetSystemMetrics(int nIndex);

        [DllImport("user32.dll")]
        private static extern bool AdjustWindowRectEx(ref RECT lpRect, uint dwStyle, bool bMenu, uint dwExStyle);

        [DllImport("user32.dll")]
        private static extern IntPtr GetDC(IntPtr hWnd);

        [DllImport("user32.dll")]
        private static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);

        // ── P/Invoke: kernel32.dll ──

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr GetModuleHandleW(string lpModuleName);

        // ── P/Invoke: gdi32.dll ──

        [DllImport("gdi32.dll", SetLastError = true)]
        private static extern int ChoosePixelFormat(IntPtr hdc, ref PIXELFORMATDESCRIPTOR ppfd);

        [DllImport("gdi32.dll", SetLastError = true)]
        private static extern bool SetPixelFormat(IntPtr hdc, int format, ref PIXELFORMATDESCRIPTOR ppfd);

        [DllImport("gdi32.dll", EntryPoint = "SwapBuffers")]
        private static extern bool GdiSwapBuffers(IntPtr hdc);

        // ── P/Invoke: opengl32.dll ──

        [DllImport("opengl32.dll", SetLastError = true)]
        private static extern IntPtr wglCreateContext(IntPtr hdc);

        [DllImport("opengl32.dll", SetLastError = true)]
        private static extern bool wglMakeCurrent(IntPtr hdc, IntPtr hglrc);

        [DllImport("opengl32.dll")]
        private static extern bool wglDeleteContext(IntPtr hglrc);

        // ── Constants ──

        private const uint CS_OWNDC = 0x0020;
        private const uint WS_OVERLAPPEDWINDOW = 0x00CF0000;
        private const uint WS_POPUP = 0x80000000;
        private const uint WS_VISIBLE = 0x10000000;
        private const int CW_USEDEFAULT = unchecked((int)0x80000000);
        private const int SW_SHOW = 5;
        private const uint PM_REMOVE = 0x0001;
        private const int SM_CXSCREEN = 0;
        private const int SM_CYSCREEN = 1;

        private const uint PFD_DRAW_TO_WINDOW = 0x04;
        private const uint PFD_SUPPORT_OPENGL = 0x20;
        private const uint PFD_DOUBLEBUFFER = 0x01;
        private const byte PFD_TYPE_RGBA = 0;
        private const byte PFD_MAIN_PLANE = 0;

        private const uint WM_CLOSE = 0x0010;
        private const uint WM_DESTROY = 0x0002;
        private const uint WM_SIZE = 0x0005;
        private const uint WM_KEYDOWN = 0x0100;
        private const uint WM_KEYUP = 0x0101;
        private const uint WM_SYSKEYDOWN = 0x0104;
        private const uint WM_SYSKEYUP = 0x0105;
        private const uint WM_MOUSEMOVE = 0x0200;
        private const uint WM_LBUTTONDOWN = 0x0201;
        private const uint WM_LBUTTONUP = 0x0202;
        private const uint WM_RBUTTONDOWN = 0x0204;
        private const uint WM_RBUTTONUP = 0x0205;
        private const uint WM_MBUTTONDOWN = 0x0207;
        private const uint WM_MBUTTONUP = 0x0208;
        private const uint WM_SETFOCUS = 0x0007;
        private const uint WM_KILLFOCUS = 0x0008;

        private static readonly IntPtr IDC_ARROW = (IntPtr)32512;

        // ── Instance state ──

        private IntPtr _hWnd;
        private IntPtr _hDC;
        private IntPtr _hGLRC;
        private WndProcDelegate _wndProc;
        private bool _isClosing;
        private int _width;
        private int _height;
        private bool _hasFocus;

        // Input state
        private readonly bool[] _keys = new bool[256];
        private readonly bool[] _mouseButtons = new bool[3];

        // Mouse grab state
        private bool _cursorGrabbed;

        // Events
        public event Action<int> KeyDown;
        public event Action<int> KeyUp;
        public event Action<int, int> Resize;

        public Win32Window(int width, int height, string title, bool fullscreen)
        {
            _width = width;
            _height = height;
            _hasFocus = true;

            var hInstance = GetModuleHandleW(null);

            _wndProc = WndProc;

            var wc = new WNDCLASSEXW
            {
                cbSize = (uint)Marshal.SizeOf<WNDCLASSEXW>(),
                style = CS_OWNDC,
                lpfnWndProc = _wndProc,
                hInstance = hInstance,
                hCursor = LoadCursorW(IntPtr.Zero, IDC_ARROW),
                lpszClassName = "ManagedDoomWin32"
            };

            RegisterClassExW(ref wc);

            uint winStyle;
            int x, y, winWidth, winHeight;

            if (fullscreen)
            {
                winStyle = WS_POPUP | WS_VISIBLE;
                x = 0;
                y = 0;
                winWidth = GetSystemMetrics(SM_CXSCREEN);
                winHeight = GetSystemMetrics(SM_CYSCREEN);
                _width = winWidth;
                _height = winHeight;
            }
            else
            {
                winStyle = WS_OVERLAPPEDWINDOW;
                var rect = new RECT { Left = 0, Top = 0, Right = width, Bottom = height };
                AdjustWindowRectEx(ref rect, winStyle, false, 0);
                winWidth = rect.Right - rect.Left;
                winHeight = rect.Bottom - rect.Top;
                x = CW_USEDEFAULT;
                y = CW_USEDEFAULT;
            }

            // SetPixelFormat can only be called once per window, so we must
            // create a fresh window for each pixel format attempt.
            var pfdConfigs = new (byte colorBits, byte depthBits, byte stencilBits, uint flags)[]
            {
                (32, 24, 8, PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER),
                (24, 24, 8, PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER),
                (32, 16, 0, PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER),
                (24, 16, 0, PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER),
                (16, 16, 0, PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER),
                (32,  0, 0, PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER),
                (24,  0, 0, PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER),
                (32,  0, 0, PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL),
            };

            foreach (var (colorBits, depthBits, stencilBits, flags) in pfdConfigs)
            {
                // Create window
                var hWnd = CreateWindowExW(
                    0, "ManagedDoomWin32", title, winStyle,
                    x, y, winWidth, winHeight,
                    IntPtr.Zero, IntPtr.Zero, hInstance, IntPtr.Zero);

                if (hWnd == IntPtr.Zero)
                    throw new Exception("CreateWindowExW failed");

                var hDC = GetDC(hWnd);
                if (hDC == IntPtr.Zero)
                {
                    DestroyWindow(hWnd);
                    throw new Exception("GetDC failed");
                }

                var pfd = new PIXELFORMATDESCRIPTOR
                {
                    nSize = (ushort)Marshal.SizeOf<PIXELFORMATDESCRIPTOR>(),
                    nVersion = 1,
                    dwFlags = flags,
                    iPixelType = PFD_TYPE_RGBA,
                    cColorBits = colorBits,
                    cDepthBits = depthBits,
                    cStencilBits = stencilBits,
                    iLayerType = PFD_MAIN_PLANE
                };

                var pixelFormat = ChoosePixelFormat(hDC, ref pfd);
                if (pixelFormat == 0)
                {
                    ReleaseDC(hWnd, hDC);
                    DestroyWindow(hWnd);
                    continue;
                }

                if (!SetPixelFormat(hDC, pixelFormat, ref pfd))
                {
                    ReleaseDC(hWnd, hDC);
                    DestroyWindow(hWnd);
                    continue;
                }

                var hGLRC = wglCreateContext(hDC);
                if (hGLRC == IntPtr.Zero)
                {
                    ReleaseDC(hWnd, hDC);
                    DestroyWindow(hWnd);
                    continue;
                }

                _hWnd = hWnd;
                _hDC = hDC;
                _hGLRC = hGLRC;
                break;
            }

            if (_hGLRC == IntPtr.Zero)
                throw new Exception("wglCreateContext failed with all pixel formats. Does this VM have OpenGL support?");

            if (!wglMakeCurrent(_hDC, _hGLRC))
                throw new Exception($"wglMakeCurrent failed (error {Marshal.GetLastWin32Error()})");

            ShowWindow(_hWnd, SW_SHOW);
            UpdateWindow(_hWnd);
        }

        private static int ResolveVirtualKey(int vk, long lParam)
        {
            var scanCode = (int)((lParam >> 16) & 0xFF);
            var extended = ((lParam >> 24) & 1) != 0;

            switch (vk)
            {
                case 0x10: // VK_SHIFT
                    return scanCode == 0x36 ? 0xA1 : 0xA0;
                case 0x11: // VK_CONTROL
                    return extended ? 0xA3 : 0xA2;
                case 0x12: // VK_MENU (Alt)
                    return extended ? 0xA5 : 0xA4;
                default:
                    return vk;
            }
        }

        private IntPtr WndProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam)
        {
            switch (msg)
            {
                case WM_CLOSE:
                    _isClosing = true;
                    return IntPtr.Zero;

                case WM_DESTROY:
                    PostQuitMessage(0);
                    return IntPtr.Zero;

                case WM_SIZE:
                    _width = (int)(lParam.ToInt64() & 0xFFFF);
                    _height = (int)((lParam.ToInt64() >> 16) & 0xFFFF);
                    Resize?.Invoke(_width, _height);
                    return IntPtr.Zero;

                case WM_SETFOCUS:
                    _hasFocus = true;
                    return IntPtr.Zero;

                case WM_KILLFOCUS:
                    _hasFocus = false;
                    if (_cursorGrabbed)
                    {
                        ClipCursor(IntPtr.Zero);
                    }
                    for (int i = 0; i < _keys.Length; i++) _keys[i] = false;
                    for (int i = 0; i < _mouseButtons.Length; i++) _mouseButtons[i] = false;
                    return IntPtr.Zero;

                case WM_KEYDOWN:
                case WM_SYSKEYDOWN:
                {
                    var vk = ResolveVirtualKey((int)wParam, lParam.ToInt64());
                    if (vk < 256 && !_keys[vk])
                    {
                        _keys[vk] = true;
                        KeyDown?.Invoke(vk);
                    }
                    if (msg == WM_SYSKEYDOWN)
                        return IntPtr.Zero;
                    break;
                }

                case WM_KEYUP:
                case WM_SYSKEYUP:
                {
                    var vk = ResolveVirtualKey((int)wParam, lParam.ToInt64());
                    if (vk < 256)
                    {
                        _keys[vk] = false;
                        KeyUp?.Invoke(vk);
                    }
                    if (msg == WM_SYSKEYUP)
                        return IntPtr.Zero;
                    break;
                }

                case WM_MOUSEMOVE:
                    return IntPtr.Zero;

                case WM_LBUTTONDOWN:
                    _mouseButtons[0] = true;
                    return IntPtr.Zero;
                case WM_LBUTTONUP:
                    _mouseButtons[0] = false;
                    return IntPtr.Zero;
                case WM_RBUTTONDOWN:
                    _mouseButtons[1] = true;
                    return IntPtr.Zero;
                case WM_RBUTTONUP:
                    _mouseButtons[1] = false;
                    return IntPtr.Zero;
                case WM_MBUTTONDOWN:
                    _mouseButtons[2] = true;
                    return IntPtr.Zero;
                case WM_MBUTTONUP:
                    _mouseButtons[2] = false;
                    return IntPtr.Zero;
            }

            return DefWindowProcW(hWnd, msg, wParam, lParam);
        }

        public void DoEvents()
        {
            while (PeekMessageW(out var msg, IntPtr.Zero, 0, 0, PM_REMOVE))
            {
                TranslateMessage(ref msg);
                DispatchMessageW(ref msg);
            }
        }

        public void SwapBuffers()
        {
            GdiSwapBuffers(_hDC);
        }

        public void Close()
        {
            _isClosing = true;
        }

        // ── Mouse cursor control ──

        public void GrabCursor()
        {
            if (_cursorGrabbed) return;

            _cursorGrabbed = true;
            ShowCursor(false);

            // Clip cursor to client area
            GetClientRect(_hWnd, out var clientRect);
            var topLeft = new POINT { X = clientRect.Left, Y = clientRect.Top };
            var bottomRight = new POINT { X = clientRect.Right, Y = clientRect.Bottom };
            ClientToScreen(_hWnd, ref topLeft);
            ClientToScreen(_hWnd, ref bottomRight);
            var screenRect = new RECT
            {
                Left = topLeft.X, Top = topLeft.Y,
                Right = bottomRight.X, Bottom = bottomRight.Y
            };
            ClipCursor(ref screenRect);

            // Center cursor
            CenterCursorInternal();
        }

        public void ReleaseCursor()
        {
            if (!_cursorGrabbed) return;

            _cursorGrabbed = false;
            ClipCursor(IntPtr.Zero);
            ShowCursor(true);

            // Move cursor to bottom-right of client area
            GetClientRect(_hWnd, out var rect);
            var pt = new POINT { X = rect.Right - 10, Y = rect.Bottom - 10 };
            ClientToScreen(_hWnd, ref pt);
            SetCursorPos(pt.X, pt.Y);
        }

        public (float deltaX, float deltaY) GetMouseDelta()
        {
            if (!_cursorGrabbed)
                return (0, 0);

            // Get current cursor position in screen coords
            GetCursorPos(out var cursorPos);

            // Get window center in screen coords
            GetClientRect(_hWnd, out var rect);
            var center = new POINT
            {
                X = (rect.Left + rect.Right) / 2,
                Y = (rect.Top + rect.Bottom) / 2
            };
            ClientToScreen(_hWnd, ref center);

            float dx = cursorPos.X - center.X;
            float dy = cursorPos.Y - center.Y;

            // Re-center cursor
            if (dx != 0 || dy != 0)
            {
                SetCursorPos(center.X, center.Y);
            }

            return (dx, dy);
        }

        private void CenterCursorInternal()
        {
            GetClientRect(_hWnd, out var rect);
            var center = new POINT
            {
                X = (rect.Left + rect.Right) / 2,
                Y = (rect.Top + rect.Bottom) / 2
            };
            ClientToScreen(_hWnd, ref center);
            SetCursorPos(center.X, center.Y);
        }

        // ── Static helpers ──

        public static (int width, int height) GetScreenResolution()
        {
            return (GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN));
        }

        // ── Properties ──

        public bool IsClosing => _isClosing;
        public int Width => _width;
        public int Height => _height;
        public bool HasFocus => _hasFocus;
        public IntPtr HDC => _hDC;
        public bool IsKeyDown(int vk) => vk >= 0 && vk < 256 && _keys[vk];
        public bool IsMouseButtonDown(int button) => button >= 0 && button < 3 && _mouseButtons[button];

        public void Dispose()
        {
            if (_cursorGrabbed)
            {
                ClipCursor(IntPtr.Zero);
                ShowCursor(true);
                _cursorGrabbed = false;
            }

            if (_hGLRC != IntPtr.Zero)
            {
                wglMakeCurrent(IntPtr.Zero, IntPtr.Zero);
                wglDeleteContext(_hGLRC);
                _hGLRC = IntPtr.Zero;
            }

            if (_hDC != IntPtr.Zero && _hWnd != IntPtr.Zero)
            {
                ReleaseDC(_hWnd, _hDC);
                _hDC = IntPtr.Zero;
            }

            if (_hWnd != IntPtr.Zero)
            {
                DestroyWindow(_hWnd);
                _hWnd = IntPtr.Zero;
            }
        }
    }
}
