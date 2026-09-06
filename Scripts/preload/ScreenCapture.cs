// Windows-only desktop screenshot capture, exposed as an autoload
// so GDScript can call ScreenCapture.GetScreenshotPng() and get back
// a PNG byte buffer ready to base64-encode and send to Ollama.
//
// Uses raw GDI32 (same style as TransparentWindow.cs) instead of
// System.Drawing.Common, so no extra NuGet package is required.

using Godot;
using System;
using System.Runtime.InteropServices;

public partial class ScreenCapture : Node // Autoloaded
{
    [DllImport("user32.dll")] private static extern IntPtr GetDC(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern int ReleaseDC(IntPtr hwnd, IntPtr hdc);
    [DllImport("gdi32.dll")] private static extern IntPtr CreateCompatibleDC(IntPtr hdc);
    [DllImport("gdi32.dll")] private static extern IntPtr CreateCompatibleBitmap(IntPtr hdc, int width, int height);
    [DllImport("gdi32.dll")] private static extern IntPtr SelectObject(IntPtr hdc, IntPtr hgdiobj);
    [DllImport("gdi32.dll")] private static extern bool BitBlt(IntPtr hdcDest, int xDest, int yDest, int width, int height, IntPtr hdcSrc, int xSrc, int ySrc, uint rop);
    [DllImport("gdi32.dll")] private static extern int GetDIBits(IntPtr hdc, IntPtr hbmp, uint start, uint cLines, [Out] byte[] lpvBits, ref BITMAPINFO lpbi, uint usage);
    [DllImport("gdi32.dll")] private static extern bool DeleteDC(IntPtr hdc);
    [DllImport("gdi32.dll")] private static extern bool DeleteObject(IntPtr hobj);

    private const uint SRCCOPY = 0x00CC0020;
    private const uint DIB_RGB_COLORS = 0;
    private const uint BI_RGB = 0;

    // How wide the sent image is, in pixels. Vision models don't need
    // full 4K - downscaling keeps requests fast and cheap.
    private const int MAX_WIDTH = 1024;

    [StructLayout(LayoutKind.Sequential)]
    private struct BITMAPINFOHEADER
    {
        public uint biSize;
        public int biWidth;
        public int biHeight;
        public ushort biPlanes;
        public ushort biBitCount;
        public uint biCompression;
        public uint biSizeImage;
        public int biXPelsPerMeter;
        public int biYPelsPerMeter;
        public uint biClrUsed;
        public uint biClrImportant;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BITMAPINFO
    {
        public BITMAPINFOHEADER bmiHeader;
        public uint bmiColors; // unused at 32bpp, kept for struct layout
    }

    // Callable from GDScript as: ScreenCapture.GetScreenshotPng()
    // Returns an empty array on failure (e.g. not running on Windows).
    public byte[] GetScreenshotPng()
    {
        if (OS.GetName() != "Windows")
        {
            GD.PrintErr("ScreenCapture: only implemented for Windows right now.");
            return Array.Empty<byte>();
        }

        IntPtr hdcScreen = IntPtr.Zero;
        IntPtr hdcMem = IntPtr.Zero;
        IntPtr hBitmap = IntPtr.Zero;

        try
        {
            Vector2I size = DisplayServer.ScreenGetSize(0);
            int width = size.X;
            int height = size.Y;
            if (width <= 0 || height <= 0)
                return Array.Empty<byte>();

            hdcScreen = GetDC(IntPtr.Zero);
            hdcMem = CreateCompatibleDC(hdcScreen);
            hBitmap = CreateCompatibleBitmap(hdcScreen, width, height);
            IntPtr hOld = SelectObject(hdcMem, hBitmap);

            BitBlt(hdcMem, 0, 0, width, height, hdcScreen, 0, 0, SRCCOPY);

            var bmi = new BITMAPINFO();
            bmi.bmiHeader.biSize = (uint)Marshal.SizeOf<BITMAPINFOHEADER>();
            bmi.bmiHeader.biWidth = width;
            bmi.bmiHeader.biHeight = -height; // negative height = top-down DIB
            bmi.bmiHeader.biPlanes = 1;
            bmi.bmiHeader.biBitCount = 32;
            bmi.bmiHeader.biCompression = BI_RGB;

            byte[] pixels = new byte[width * height * 4];
            GetDIBits(hdcMem, hBitmap, 0, (uint)height, pixels, ref bmi, DIB_RGB_COLORS);

            SelectObject(hdcMem, hOld);

            // GDI gives BGRA, Godot's Image wants RGBA.
            for (int i = 0; i < pixels.Length; i += 4)
            {
                (pixels[i], pixels[i + 2]) = (pixels[i + 2], pixels[i]);
                pixels[i + 3] = 255;
            }

            var img = Image.CreateFromData(width, height, false, Image.Format.Rgba8, pixels);

            if (width > MAX_WIDTH)
            {
                int newHeight = Mathf.RoundToInt((float)MAX_WIDTH * height / width);
                img.Resize(MAX_WIDTH, newHeight);
            }

            return img.SavePngToBuffer();
        }
        catch (Exception e)
        {
            GD.PrintErr("ScreenCapture failed: ", e.Message);
            return Array.Empty<byte>();
        }
        finally
        {
            if (hBitmap != IntPtr.Zero) DeleteObject(hBitmap);
            if (hdcMem != IntPtr.Zero) DeleteDC(hdcMem);
            if (hdcScreen != IntPtr.Zero) ReleaseDC(IntPtr.Zero, hdcScreen);
        }
    }
}
