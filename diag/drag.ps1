# Diagnostic only (stremio-bugs#2827): perform a real OLE file drag (the same CF_HDROP data Explorer provides)
# from a helper window onto screen point (X, Y). Run with: powershell.exe -STA -File drag.ps1 -File <path> -X <x> -Y <y>
param([string]$File, [int]$X, [int]$Y)
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @"
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

public static class Dragger {
    [DllImport("user32.dll")] static extern void mouse_event(uint flags, int dx, int dy, uint data, UIntPtr extra);
    const uint MOVE = 0x0001, LEFTDOWN = 0x0002, LEFTUP = 0x0004, ABSOLUTE = 0x8000;

    static void MoveTo(int x, int y) {
        Rectangle screen = Screen.PrimaryScreen.Bounds;
        int nx = (int)Math.Round(x * 65535.0 / (screen.Width - 1));
        int ny = (int)Math.Round(y * 65535.0 / (screen.Height - 1));
        mouse_event(MOVE | ABSOLUTE, nx, ny, 0, UIntPtr.Zero);
    }

    public static string Run(string file, int tx, int ty) {
        string result = "no-drag";
        Form form = new Form();
        form.StartPosition = FormStartPosition.Manual;
        form.Location = new Point(5, 5);
        form.Size = new Size(170, 110);
        form.TopMost = true;
        form.Text = "drag-source";
        Label label = new Label();
        label.Dock = DockStyle.Fill;
        label.Text = "drag source";
        form.Controls.Add(label);
        label.MouseDown += (s, e) => {
            DataObject data = new DataObject(DataFormats.FileDrop, new string[] { file });
            DragDropEffects effect = label.DoDragDrop(data, DragDropEffects.Copy | DragDropEffects.Link | DragDropEffects.Move);
            result = "drag-effect=" + effect;
            form.BeginInvoke((Action)(() => form.Close()));
        };
        form.Shown += (s, e) => {
            Point src = label.PointToScreen(new Point(40, 30));
            Thread t = new Thread(() => {
                Thread.Sleep(700);
                MoveTo(src.X, src.Y);
                Thread.Sleep(200);
                mouse_event(LEFTDOWN, 0, 0, 0, UIntPtr.Zero);
                Thread.Sleep(200);
                for (int i = 1; i <= 40; i++) {
                    MoveTo(src.X + (tx - src.X) * i / 40, src.Y + (ty - src.Y) * i / 40);
                    Thread.Sleep(25);
                }
                for (int i = 0; i < 6; i++) { MoveTo(tx + (i % 2), ty); Thread.Sleep(100); }
                Thread.Sleep(400);
                mouse_event(LEFTUP, 0, 0, 0, UIntPtr.Zero);
                Thread.Sleep(8000);
                try { form.BeginInvoke((Action)(() => form.Close())); } catch { }
            });
            t.IsBackground = true;
            t.Start();
        };
        Application.Run(form);
        return result;
    }
}
"@
[Dragger]::Run($File, $X, $Y)
