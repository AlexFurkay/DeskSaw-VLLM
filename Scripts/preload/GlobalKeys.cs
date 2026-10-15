// Autoload: GlobalKeys - глобальная клавиатура для режима игрока (054P).
//
// Окно DeskSaw прозрачное и пропускает клики, поэтому почти никогда не
// бывает в фокусе - обычный ввод Godot клавиш не видит. Здесь стоит
// низкоуровневый перехватчик клавиатуры Windows (WH_KEYBOARD_LL):
//  - сочетание режима игрока (по умолчанию Ctrl+Alt+P) ловится всегда,
//    в какой бы программе ни был фокус;
//  - в режиме управления клавиши движения и Enter забираются себе и НЕ
//    доходят до других программ;
//  - пока открыт чат - забирается весь набираемый текст (с учётом текущей
//    раскладки, в т.ч. русской), Enter/Backspace/Esc.
// На других ОС ничего не делает.
using Godot;
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public partial class GlobalKeys : Node
{
    [Signal] public delegate void ToggleRequestedEventHandler();
    [Signal] public delegate void EnterPressedEventHandler();
    [Signal] public delegate void TextCharEventHandler(string ch);
    [Signal] public delegate void BackspacePressedEventHandler();
    [Signal] public delegate void EscapePressedEventHandler();

    private delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc lpfn, IntPtr hMod, uint dwThreadId);
    [DllImport("user32.dll")]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);
    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr GetModuleHandle(string lpModuleName);
    [DllImport("user32.dll")]
    private static extern int ToUnicodeEx(uint wVirtKey, uint wScanCode, byte[] lpKeyState,
        [Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pwszBuff, int cchBuff, uint wFlags, IntPtr dwhkl);
    [DllImport("user32.dll")]
    private static extern IntPtr GetKeyboardLayout(uint idThread);
    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, IntPtr lpdwProcessId);
    [DllImport("user32.dll")]
    private static extern short GetKeyState(int nVirtKey);

    [StructLayout(LayoutKind.Sequential)]
    private struct KBDLLHOOKSTRUCT
    {
        public uint vkCode;
        public uint scanCode;
        public uint flags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    private const int WH_KEYBOARD_LL = 13;
    private const int WM_KEYDOWN = 0x100, WM_KEYUP = 0x101, WM_SYSKEYDOWN = 0x104, WM_SYSKEYUP = 0x105;
    private const uint VK_BACK = 0x08, VK_RETURN = 0x0D, VK_ESCAPE = 0x1B;

    private static readonly uint[] CtrlKeys = { 0xA2, 0xA3, 0x11 };
    private static readonly uint[] AltKeys = { 0xA4, 0xA5, 0x12 };
    private static readonly uint[] ShiftKeys = { 0xA0, 0xA1, 0x10 };
    private static readonly uint[] WinKeys = { 0x5B, 0x5C };
    // A, D, W, пробел, стрелки - забираются в режиме управления
    private static readonly HashSet<uint> MovementKeys = new() { 0x41, 0x44, 0x57, 0x53, 0x20, 0x25, 0x26, 0x27, 0x28 }; // +S (0x53) - сесть

    private LowLevelKeyboardProc _proc; // ссылка обязательна - иначе сборщик мусора удалит делегат, и хук упадёт
    private IntPtr _hook = IntPtr.Zero;
    private readonly HashSet<uint> _down = new();
    private readonly ConcurrentQueue<(string type, string data)> _events = new();

    private readonly List<uint[]> _comboModifiers = new();
    private uint _comboKey = 0x50; // P
    private bool _captureMovement = false;
    private bool _captureText = false;

    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int vKey);

    private bool _isWindows = false;
    private bool _comboWasDown = false;

    // ВАЖНО: перехватчик ставится ТОЛЬКО на время режима управления/чата.
    // Пока он стоит, Windows ждёт игру на каждое нажатие клавиши в любой
    // программе - если игра подвиснет, лагала бы клавиатура во всей системе.
    // Вне режима сочетание просто опрашивается раз в кадр (GetAsyncKeyState).
    public override void _Ready()
    {
        SetCombo("Ctrl+Alt+P");
        _isWindows = OS.GetName() == "Windows";
        _proc = HookCallback;
    }

    public override void _ExitTree()
    {
        RemoveHook();
    }

    private void UpdateHook()
    {
        if (!_isWindows) return;
        bool need = _captureMovement || _captureText;
        if (need && _hook == IntPtr.Zero)
        {
            _down.Clear();
            _hook = SetWindowsHookEx(WH_KEYBOARD_LL, _proc, GetModuleHandle(null), 0);
            if (_hook == IntPtr.Zero)
                GD.PrintErr("GlobalKeys: не удалось поставить перехватчик клавиатуры");
        }
        else if (!need)
        {
            RemoveHook();
        }
    }

    private void RemoveHook()
    {
        if (_hook != IntPtr.Zero)
        {
            UnhookWindowsHookEx(_hook);
            _hook = IntPtr.Zero;
        }
        _down.Clear();
    }

    private static bool AsyncDown(uint vk) => (GetAsyncKeyState((int)vk) & 0x8000) != 0;

    private void PollCombo()
    {
        bool modsHeld = true;
        foreach (var group in _comboModifiers)
        {
            bool any = false;
            foreach (var k in group)
                if (AsyncDown(k)) { any = true; break; }
            if (!any) { modsHeld = false; break; }
        }
        bool down = modsHeld && AsyncDown(_comboKey);
        if (down && !_comboWasDown)
            _events.Enqueue(("toggle", ""));
        _comboWasDown = down;
    }

    public override void _Process(double delta)
    {
        if (_isWindows && _hook == IntPtr.Zero)
            PollCombo(); // перехватчика нет - сочетание ловим опросом
        else
            _comboWasDown = true; // чтобы после снятия перехватчика удержанная клавиша не сработала повторно
        while (_events.TryDequeue(out var e))
        {
            switch (e.type)
            {
                case "toggle": EmitSignal(SignalName.ToggleRequested); break;
                case "enter": EmitSignal(SignalName.EnterPressed); break;
                case "char": EmitSignal(SignalName.TextChar, e.data); break;
                case "back": EmitSignal(SignalName.BackspacePressed); break;
                case "esc": EmitSignal(SignalName.EscapePressed); break;
            }
        }
    }

    public void SetCaptureMovement(bool on) { _captureMovement = on; UpdateHook(); }
    public void SetCaptureText(bool on) { _captureText = on; UpdateHook(); }

    public bool IsKeyDown(int vk) { return _down.Contains((uint)vk); }

    /// "Ctrl+Alt+P", "Shift+F5", "Ctrl+Shift+K"... Возвращает false, если
    /// сочетание не распознано (тогда старое остаётся как было).
    public bool SetCombo(string text)
    {
        var mods = new List<uint[]>();
        uint key = 0;
        foreach (var raw in text.Split('+', StringSplitOptions.RemoveEmptyEntries))
        {
            var t = raw.Trim().ToLowerInvariant();
            switch (t)
            {
                case "ctrl": case "control": mods.Add(CtrlKeys); continue;
                case "alt": mods.Add(AltKeys); continue;
                case "shift": mods.Add(ShiftKeys); continue;
                case "win": mods.Add(WinKeys); continue;
            }
            if (key != 0)
                return false; // только одна обычная клавиша
            key = ParseKey(t);
            if (key == 0)
                return false;
        }
        if (key == 0)
            return false;
        _comboModifiers.Clear();
        _comboModifiers.AddRange(mods);
        _comboKey = key;
        return true;
    }

    private static uint ParseKey(string t)
    {
        if (t.Length == 1)
        {
            char c = char.ToUpperInvariant(t[0]);
            if (c >= 'A' && c <= 'Z') return c;
            if (c >= '0' && c <= '9') return c;
        }
        if (t.Length >= 2 && t[0] == 'f' && int.TryParse(t.Substring(1), out int n) && n >= 1 && n <= 24)
            return (uint)(0x70 + n - 1);
        return t switch
        {
            "space" => 0x20,
            "tab" => 0x09,
            "home" => 0x24,
            "end" => 0x23,
            "insert" => 0x2D,
            "delete" => 0x2E,
            "pageup" => 0x21,
            "pagedown" => 0x22,
            "left" => 0x25,
            "up" => 0x26,
            "right" => 0x27,
            "down" => 0x28,
            _ => 0,
        };
    }

    private bool AnyDown(uint[] keys)
    {
        foreach (var k in keys)
            if (_down.Contains(k)) return true;
        return false;
    }

    private bool ComboModifiersHeld()
    {
        foreach (var group in _comboModifiers)
            if (!AnyDown(group)) return false;
        return true;
    }

    private static bool IsModifier(uint vk)
    {
        return Array.IndexOf(CtrlKeys, vk) >= 0 || Array.IndexOf(AltKeys, vk) >= 0
            || Array.IndexOf(ShiftKeys, vk) >= 0 || Array.IndexOf(WinKeys, vk) >= 0;
    }

    private string Translate(uint vk, uint scan)
    {
        var state = new byte[256];
        if (AnyDown(ShiftKeys)) state[0x10] = 0x80;
        if (AnyDown(CtrlKeys)) state[0x11] = 0x80;
        if (AnyDown(AltKeys)) state[0x12] = 0x80;
        if ((GetKeyState(0x14) & 1) != 0) state[0x14] = 0x01; // Caps Lock
        var layout = GetKeyboardLayout(GetWindowThreadProcessId(GetForegroundWindow(), IntPtr.Zero));
        var sb = new StringBuilder(8);
        int n = ToUnicodeEx(vk, scan, state, sb, sb.Capacity, 0x4, layout); // 0x4: не трогать состояние клавиатуры
        return n > 0 ? sb.ToString(0, n) : "";
    }

    private IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            var kb = Marshal.PtrToStructure<KBDLLHOOKSTRUCT>(lParam);
            int msg = (int)wParam;
            bool down = msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN;
            bool up = msg == WM_KEYUP || msg == WM_SYSKEYUP;
            uint vk = kb.vkCode;
            if (down) _down.Add(vk);
            else if (up) _down.Remove(vk);

            if (down && vk == _comboKey && ComboModifiersHeld())
            {
                _events.Enqueue(("toggle", ""));
                return (IntPtr)1;
            }

            if (_captureText)
            {
                if (IsModifier(vk))
                    return CallNextHookEx(_hook, nCode, wParam, lParam); // модификаторы пропускаем, чтобы Windows не "залипла" на Shift/Alt
                if (down)
                {
                    if (vk == VK_RETURN) _events.Enqueue(("enter", ""));
                    else if (vk == VK_ESCAPE) _events.Enqueue(("esc", ""));
                    else if (vk == VK_BACK) _events.Enqueue(("back", ""));
                    else if (!AnyDown(CtrlKeys))
                    {
                        var s = Translate(vk, kb.scanCode);
                        if (s.Length > 0 && !char.IsControl(s[0]))
                            _events.Enqueue(("char", s));
                    }
                }
                return (IntPtr)1;
            }

            if (_captureMovement && (MovementKeys.Contains(vk) || vk == VK_RETURN))
            {
                if (down && vk == VK_RETURN)
                    _events.Enqueue(("enter", ""));
                return (IntPtr)1;
            }
        }
        return CallNextHookEx(_hook, nCode, wParam, lParam);
    }
}
