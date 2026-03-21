using System;
using System.Runtime.ExceptionServices;
using ManagedDoom.UserInput;

namespace ManagedDoom.Silk
{
    public class SilkUserInput : IUserInput, IDisposable
    {
        private Config config;
        private Win32Window window;

        private bool[] weaponKeys;
        private int turnHeld;

        private bool useMouse;
        private bool mouseGrabbed;
        private float mouseDeltaX;
        private float mouseDeltaY;

        public SilkUserInput(Config config, Win32Window window, SilkDoom doom, bool useMouse)
        {
            try
            {
                Console.Write("Initialize user input: ");

                this.config = config;
                this.window = window;
                this.useMouse = useMouse;

                window.KeyDown += vk => doom.KeyDown(vk);
                window.KeyUp += vk => doom.KeyUp(vk);

                weaponKeys = new bool[7];
                turnHeld = 0;

                Console.WriteLine("OK");
            }
            catch (Exception e)
            {
                Console.WriteLine("Failed");
                Dispose();
                ExceptionDispatchInfo.Throw(e);
            }
        }

        public void BuildTicCmd(TicCmd cmd)
        {
            var keyForward = IsPressed(config.key_forward);
            var keyBackward = IsPressed(config.key_backward);
            var keyStrafeLeft = IsPressed(config.key_strafeleft);
            var keyStrafeRight = IsPressed(config.key_straferight);
            var keyTurnLeft = IsPressed(config.key_turnleft);
            var keyTurnRight = IsPressed(config.key_turnright);
            var keyFire = IsPressed(config.key_fire);
            var keyUse = IsPressed(config.key_use);
            var keyRun = IsPressed(config.key_run);
            var keyStrafe = IsPressed(config.key_strafe);

            // Number keys 1-7 (VK '1' = 0x31 .. '7' = 0x37)
            weaponKeys[0] = window.IsKeyDown(0x31);
            weaponKeys[1] = window.IsKeyDown(0x32);
            weaponKeys[2] = window.IsKeyDown(0x33);
            weaponKeys[3] = window.IsKeyDown(0x34);
            weaponKeys[4] = window.IsKeyDown(0x35);
            weaponKeys[5] = window.IsKeyDown(0x36);
            weaponKeys[6] = window.IsKeyDown(0x37);

            cmd.Clear();

            var strafe = keyStrafe;
            var speed = keyRun ? 1 : 0;
            var forward = 0;
            var side = 0;

            if (config.game_alwaysrun)
            {
                speed = 1 - speed;
            }

            if (keyTurnLeft || keyTurnRight)
            {
                turnHeld++;
            }
            else
            {
                turnHeld = 0;
            }

            int turnSpeed;
            if (turnHeld < PlayerBehavior.SlowTurnTics)
            {
                turnSpeed = 2;
            }
            else
            {
                turnSpeed = speed;
            }

            if (strafe)
            {
                if (keyTurnRight)
                {
                    side += PlayerBehavior.SideMove[speed];
                }
                if (keyTurnLeft)
                {
                    side -= PlayerBehavior.SideMove[speed];
                }
            }
            else
            {
                if (keyTurnRight)
                {
                    cmd.AngleTurn -= (short)PlayerBehavior.AngleTurn[turnSpeed];
                }
                if (keyTurnLeft)
                {
                    cmd.AngleTurn += (short)PlayerBehavior.AngleTurn[turnSpeed];
                }
            }

            if (keyForward)
            {
                forward += PlayerBehavior.ForwardMove[speed];
            }
            if (keyBackward)
            {
                forward -= PlayerBehavior.ForwardMove[speed];
            }

            if (keyStrafeLeft)
            {
                side -= PlayerBehavior.SideMove[speed];
            }
            if (keyStrafeRight)
            {
                side += PlayerBehavior.SideMove[speed];
            }

            if (keyFire)
            {
                cmd.Buttons |= TicCmdButtons.Attack;
            }

            if (keyUse)
            {
                cmd.Buttons |= TicCmdButtons.Use;
            }

            // Check weapon keys.
            for (var i = 0; i < weaponKeys.Length; i++)
            {
                if (weaponKeys[i])
                {
                    cmd.Buttons |= TicCmdButtons.Change;
                    cmd.Buttons |= (byte)(i << TicCmdButtons.WeaponShift);
                    break;
                }
            }

            UpdateMouse();
            var ms = 0.5F * config.mouse_sensitivity;
            var mx = (int)MathF.Round(ms * mouseDeltaX);
            var my = (int)MathF.Round(ms * -mouseDeltaY);
            forward += my;
            if (strafe)
            {
                side += mx * 2;
            }
            else
            {
                cmd.AngleTurn -= (short)(mx * 0x8);
            }

            if (forward > PlayerBehavior.MaxMove)
            {
                forward = PlayerBehavior.MaxMove;
            }
            else if (forward < -PlayerBehavior.MaxMove)
            {
                forward = -PlayerBehavior.MaxMove;
            }
            if (side > PlayerBehavior.MaxMove)
            {
                side = PlayerBehavior.MaxMove;
            }
            else if (side < -PlayerBehavior.MaxMove)
            {
                side = -PlayerBehavior.MaxMove;
            }

            cmd.ForwardMove += (sbyte)forward;
            cmd.SideMove += (sbyte)side;
        }

        private bool IsPressed(KeyBinding keyBinding)
        {
            foreach (var key in keyBinding.Keys)
            {
                var vk = DoomToVk(key);
                if (vk >= 0 && window.IsKeyDown(vk))
                {
                    return true;
                }
            }

            if (mouseGrabbed && useMouse)
            {
                foreach (var mouseButton in keyBinding.MouseButtons)
                {
                    if (window.IsMouseButtonDown((int)mouseButton))
                    {
                        return true;
                    }
                }
            }

            return false;
        }

        public void Reset()
        {
            if (!useMouse) return;

            mouseDeltaX = 0;
            mouseDeltaY = 0;
        }

        public void GrabMouse()
        {
            if (!useMouse) return;

            if (!mouseGrabbed)
            {
                window.GrabCursor();
                mouseGrabbed = true;
                mouseDeltaX = 0;
                mouseDeltaY = 0;
            }
        }

        public void ReleaseMouse()
        {
            if (!useMouse) return;

            if (mouseGrabbed)
            {
                window.ReleaseCursor();
                mouseGrabbed = false;
            }
        }

        private void UpdateMouse()
        {
            if (!useMouse) return;

            if (mouseGrabbed)
            {
                var (dx, dy) = window.GetMouseDelta();
                mouseDeltaX = dx;
                mouseDeltaY = dy;

                if (config.mouse_disableyaxis)
                {
                    mouseDeltaY = 0;
                }
            }
            else
            {
                mouseDeltaX = 0;
                mouseDeltaY = 0;
            }
        }

        public void Dispose()
        {
            Console.WriteLine("Shutdown user input.");

            if (mouseGrabbed)
            {
                window.ReleaseCursor();
                mouseGrabbed = false;
            }
        }

        // ── VK code ↔ DoomKey mapping ──

        public static DoomKey VkToDoom(int vk)
        {
            // A-Z: VK 0x41..0x5A
            if (vk >= 0x41 && vk <= 0x5A)
                return DoomKey.A + (vk - 0x41);

            // 0-9: VK 0x30..0x39
            if (vk >= 0x30 && vk <= 0x39)
                return DoomKey.Num0 + (vk - 0x30);

            // F1-F15: VK 0x70..0x7E
            if (vk >= 0x70 && vk <= 0x7E)
                return DoomKey.F1 + (vk - 0x70);

            // Numpad 0-9: VK 0x60..0x69
            if (vk >= 0x60 && vk <= 0x69)
                return DoomKey.Numpad0 + (vk - 0x60);

            return vk switch
            {
                0x20 => DoomKey.Space,
                0x1B => DoomKey.Escape,
                0x0D => DoomKey.Enter,
                0x09 => DoomKey.Tab,
                0x08 => DoomKey.Backspace,
                0x2D => DoomKey.Insert,
                0x2E => DoomKey.Delete,
                0x27 => DoomKey.Right,
                0x25 => DoomKey.Left,
                0x28 => DoomKey.Down,
                0x26 => DoomKey.Up,
                0x21 => DoomKey.PageUp,
                0x22 => DoomKey.PageDown,
                0x24 => DoomKey.Home,
                0x23 => DoomKey.End,
                0x13 => DoomKey.Pause,
                0xA0 => DoomKey.LShift,
                0xA1 => DoomKey.RShift,
                0xA2 => DoomKey.LControl,
                0xA3 => DoomKey.RControl,
                0xA4 => DoomKey.LAlt,
                0xA5 => DoomKey.RAlt,
                0x5D => DoomKey.Menu,         // VK_APPS
                0xBA => DoomKey.Semicolon,    // VK_OEM_1
                0xBB => DoomKey.Equal,        // VK_OEM_PLUS
                0xBC => DoomKey.Comma,        // VK_OEM_COMMA
                0xBD => DoomKey.Subtract,     // VK_OEM_MINUS
                0xBE => DoomKey.Period,       // VK_OEM_PERIOD
                0xBF => DoomKey.Slash,        // VK_OEM_2
                0xDB => DoomKey.LBracket,     // VK_OEM_4
                0xDC => DoomKey.Backslash,    // VK_OEM_5
                0xDD => DoomKey.RBracket,     // VK_OEM_6
                0x6A => DoomKey.Multiply,     // VK_MULTIPLY
                0x6B => DoomKey.Add,          // VK_ADD
                0x6D => DoomKey.Subtract,     // VK_SUBTRACT
                0x6F => DoomKey.Divide,       // VK_DIVIDE
                _ => DoomKey.Unknown
            };
        }

        public static int DoomToVk(DoomKey key)
        {
            // A-Z
            if (key >= DoomKey.A && key <= DoomKey.Z)
                return 0x41 + (key - DoomKey.A);

            // 0-9
            if (key >= DoomKey.Num0 && key <= DoomKey.Num9)
                return 0x30 + (key - DoomKey.Num0);

            // F1-F15
            if (key >= DoomKey.F1 && key <= DoomKey.F15)
                return 0x70 + (key - DoomKey.F1);

            // Numpad 0-9
            if (key >= DoomKey.Numpad0 && key <= DoomKey.Numpad9)
                return 0x60 + (key - DoomKey.Numpad0);

            return key switch
            {
                DoomKey.Space => 0x20,
                DoomKey.Escape => 0x1B,
                DoomKey.Enter => 0x0D,
                DoomKey.Tab => 0x09,
                DoomKey.Backspace => 0x08,
                DoomKey.Insert => 0x2D,
                DoomKey.Delete => 0x2E,
                DoomKey.Right => 0x27,
                DoomKey.Left => 0x25,
                DoomKey.Down => 0x28,
                DoomKey.Up => 0x26,
                DoomKey.PageUp => 0x21,
                DoomKey.PageDown => 0x22,
                DoomKey.Home => 0x24,
                DoomKey.End => 0x23,
                DoomKey.Pause => 0x13,
                DoomKey.LShift => 0xA0,
                DoomKey.RShift => 0xA1,
                DoomKey.LControl => 0xA2,
                DoomKey.RControl => 0xA3,
                DoomKey.LAlt => 0xA4,
                DoomKey.RAlt => 0xA5,
                DoomKey.Menu => 0x5D,
                DoomKey.Semicolon => 0xBA,
                DoomKey.Equal => 0xBB,
                DoomKey.Comma => 0xBC,
                DoomKey.Period => 0xBE,
                DoomKey.Slash => 0xBF,
                DoomKey.Backslash => 0xDC,
                DoomKey.LBracket => 0xDB,
                DoomKey.RBracket => 0xDD,
                DoomKey.Add => 0x6B,
                DoomKey.Subtract => 0x6D,
                DoomKey.Multiply => 0x6A,
                DoomKey.Divide => 0x6F,
                _ => -1
            };
        }

        public int MaxMouseSensitivity
        {
            get
            {
                return 15;
            }
        }

        public int MouseSensitivity
        {
            get
            {
                return config.mouse_sensitivity;
            }

            set
            {
                config.mouse_sensitivity = value;
            }
        }
    }
}
