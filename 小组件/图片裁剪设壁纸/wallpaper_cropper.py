#!/usr/bin/env python3
"""固定比例裁剪图片，并在 GNOME 桌面设为壁纸。"""

import math
import os
import subprocess
import sys
from datetime import datetime
from pathlib import Path

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import Gdk, GdkPixbuf, GLib, Gtk
from PIL import Image, ImageOps


class CropCanvas(Gtk.DrawingArea):
    HANDLE = 11

    def __init__(self, status_callback):
        super().__init__()
        self.set_hexpand(True)
        self.set_vexpand(True)
        self.set_size_request(720, 450)
        self.add_events(
            Gdk.EventMask.BUTTON_PRESS_MASK
            | Gdk.EventMask.BUTTON_RELEASE_MASK
            | Gdk.EventMask.POINTER_MOTION_MASK
        )
        self.connect("draw", self.on_draw)
        self.connect("button-press-event", self.on_press)
        self.connect("button-release-event", self.on_release)
        self.connect("motion-notify-event", self.on_motion)
        self.connect("size-allocate", lambda *_: self.queue_draw())
        self.status_callback = status_callback
        self.pixbuf = None
        self.path = None
        self.image_w = self.image_h = 0
        self.ratio = 16 / 9
        self.selection = None  # image coordinates: x, y, w, h
        self.view = (0, 0, 1)
        self.drag = None

    def load(self, path):
        pixbuf = GdkPixbuf.Pixbuf.new_from_file(path).apply_embedded_orientation()
        self.pixbuf, self.path = pixbuf, path
        self.image_w, self.image_h = pixbuf.get_width(), pixbuf.get_height()
        self.reset_selection()

    def set_ratio(self, ratio):
        self.ratio = ratio
        if self.pixbuf:
            self.reset_selection()

    def reset_selection(self):
        iw, ih, r = self.image_w, self.image_h, self.ratio
        if iw / ih >= r:
            h = ih * 0.82
            w = h * r
        else:
            w = iw * 0.82
            h = w / r
        self.selection = [(iw - w) / 2, (ih - h) / 2, w, h]
        self._update_status()
        self.queue_draw()

    def _layout(self):
        a = self.get_allocation()
        if not self.pixbuf:
            return 0, 0, 1
        scale = min(a.width / self.image_w, a.height / self.image_h)
        return ((a.width - self.image_w * scale) / 2,
                (a.height - self.image_h * scale) / 2, scale)

    def _screen_rect(self):
        ox, oy, s = self.view
        x, y, w, h = self.selection
        return ox + x * s, oy + y * s, w * s, h * s

    def on_draw(self, _widget, cr):
        a = self.get_allocation()
        cr.set_source_rgb(0.10, 0.10, 0.11)
        cr.paint()
        if not self.pixbuf:
            cr.set_source_rgb(0.75, 0.75, 0.75)
            cr.select_font_face("Sans")
            cr.set_font_size(20)
            text = "点击“选择图片”开始"
            ext = cr.text_extents(text)
            cr.move_to((a.width - ext.width) / 2, (a.height + ext.height) / 2)
            cr.show_text(text)
            return False

        self.view = self._layout()
        ox, oy, s = self.view
        scaled = self.pixbuf.scale_simple(
            max(1, round(self.image_w * s)), max(1, round(self.image_h * s)),
            GdkPixbuf.InterpType.BILINEAR)
        Gdk.cairo_set_source_pixbuf(cr, scaled, ox, oy)
        cr.paint()

        sx, sy, sw, sh = self._screen_rect()
        # Darken everything outside the selected region.
        cr.set_fill_rule(1)  # EVEN_ODD
        cr.rectangle(ox, oy, self.image_w * s, self.image_h * s)
        cr.rectangle(sx, sy, sw, sh)
        cr.set_source_rgba(0, 0, 0, 0.55)
        cr.fill()
        cr.set_fill_rule(0)

        cr.rectangle(sx + 0.5, sy + 0.5, sw - 1, sh - 1)
        cr.set_source_rgb(1, 1, 1)
        cr.set_line_width(2)
        cr.stroke()
        cr.set_source_rgba(1, 1, 1, 0.72)
        cr.set_line_width(1)
        for i in (1, 2):
            cr.move_to(sx + sw * i / 3, sy)
            cr.line_to(sx + sw * i / 3, sy + sh)
            cr.move_to(sx, sy + sh * i / 3)
            cr.line_to(sx + sw, sy + sh * i / 3)
        cr.stroke()
        for px, py in ((sx, sy), (sx + sw, sy), (sx, sy + sh), (sx + sw, sy + sh)):
            cr.rectangle(px - 5, py - 5, 10, 10)
            cr.set_source_rgb(1, 1, 1)
            cr.fill()
        return False

    def _hit(self, px, py):
        sx, sy, sw, sh = self._screen_rect()
        corners = {"nw": (sx, sy), "ne": (sx + sw, sy),
                   "sw": (sx, sy + sh), "se": (sx + sw, sy + sh)}
        for name, (cx, cy) in corners.items():
            if math.hypot(px - cx, py - cy) <= self.HANDLE * 1.5:
                return name
        if sx <= px <= sx + sw and sy <= py <= sy + sh:
            return "move"
        return None

    def on_press(self, _widget, event):
        if event.button != 1 or not self.selection:
            return False
        mode = self._hit(event.x, event.y)
        if mode:
            self.drag = (mode, event.x, event.y, self.selection.copy())
        return bool(mode)

    def on_release(self, *_):
        self.drag = None
        return True

    def on_motion(self, _widget, event):
        if not self.drag:
            return False
        mode, start_x, start_y, old = self.drag
        _, _, scale = self.view
        dx, dy = (event.x - start_x) / scale, (event.y - start_y) / scale
        x, y, w, h = old
        if mode == "move":
            x = min(max(0, x + dx), self.image_w - w)
            y = min(max(0, y + dy), self.image_h - h)
        else:
            anchor_x = x + w if "w" in mode else x
            anchor_y = y + h if "n" in mode else y
            pointer_x = x + dx if "w" in mode else x + w + dx
            pointer_y = y + dy if "n" in mode else y + h + dy
            max_w = anchor_x if "w" in mode else self.image_w - anchor_x
            max_h = anchor_y if "n" in mode else self.image_h - anchor_y
            desired_w = max(40 / scale, abs(pointer_x - anchor_x))
            desired_h = max(40 / scale, abs(pointer_y - anchor_y))
            # Choose the dimension that best follows the pointer, then clamp.
            if abs(desired_w - w) / max(w, 1) >= abs(desired_h - h) / max(h, 1):
                new_w = desired_w
                new_h = new_w / self.ratio
            else:
                new_h = desired_h
                new_w = new_h * self.ratio
            factor = min(1, max_w / new_w, max_h / new_h)
            new_w, new_h = new_w * factor, new_h * factor
            x = anchor_x - new_w if "w" in mode else anchor_x
            y = anchor_y - new_h if "n" in mode else anchor_y
            w, h = new_w, new_h
        self.selection = [x, y, w, h]
        self._update_status()
        self.queue_draw()
        return True

    def _update_status(self):
        if self.selection:
            _, _, w, h = self.selection
            self.status_callback(f"裁剪尺寸：{round(w)} × {round(h)} 像素")

    def crop(self, output):
        x, y, w, h = self.selection
        with Image.open(self.path) as source:
            source = ImageOps.exif_transpose(source)
            box = (round(x), round(y), round(x + w), round(y + h))
            cropped = source.crop(box)
            if cropped.mode not in ("RGB", "RGBA"):
                cropped = cropped.convert("RGB")
            cropped.save(output, "PNG", optimize=True)


class App(Gtk.Window):
    RATIOS = [("当前屏幕", None), ("16:9", 16 / 9), ("16:10", 16 / 10),
              ("4:3", 4 / 3), ("3:2", 3 / 2), ("1:1", 1), ("9:16", 9 / 16)]

    def __init__(self):
        super().__init__(title="图片裁剪设壁纸")
        self.set_default_size(980, 680)
        self.set_border_width(10)
        self.connect("destroy", Gtk.main_quit)
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.add(root)
        bar = Gtk.Box(spacing=8)
        root.pack_start(bar, False, False, 0)
        choose = Gtk.Button(label="选择图片…")
        choose.connect("clicked", self.choose_image)
        bar.pack_start(choose, False, False, 0)
        bar.pack_start(Gtk.Label(label="裁剪比例："), False, False, 0)
        self.ratios = Gtk.ComboBoxText()
        for name, _ in self.RATIOS:
            self.ratios.append_text(name)
        self.ratios.set_active(0)
        self.ratios.connect("changed", self.ratio_changed)
        bar.pack_start(self.ratios, False, False, 0)
        reset = Gtk.Button(label="重置选框")
        reset.connect("clicked", lambda *_: self.canvas.reset_selection() if self.canvas.pixbuf else None)
        bar.pack_start(reset, False, False, 0)
        restore = Gtk.Button(label="恢复系统默认壁纸")
        restore.connect("clicked", self.restore_default_wallpaper)
        bar.pack_end(restore, False, False, 0)
        apply_btn = Gtk.Button(label="裁剪并设为壁纸")
        apply_btn.get_style_context().add_class("suggested-action")
        apply_btn.connect("clicked", self.apply_wallpaper)
        bar.pack_end(apply_btn, False, False, 0)
        self.status = Gtk.Label(label="请选择一张图片", xalign=0)
        self.canvas = CropCanvas(self.status.set_text)
        root.pack_start(self.canvas, True, True, 0)
        root.pack_start(self.status, False, False, 0)
        self.canvas.set_ratio(self.screen_ratio())

    def screen_ratio(self):
        display = Gdk.Display.get_default()
        monitor = display.get_primary_monitor() if display else None
        if not monitor and display and display.get_n_monitors():
            monitor = display.get_monitor(0)
        if monitor:
            area = monitor.get_geometry()
            return area.width / area.height
        return 16 / 9

    def ratio_changed(self, combo):
        ratio = self.RATIOS[combo.get_active()][1] or self.screen_ratio()
        self.canvas.set_ratio(ratio)

    def choose_image(self, *_):
        dialog = Gtk.FileChooserDialog(
            title="选择图片", parent=self, action=Gtk.FileChooserAction.OPEN,
            buttons=("取消", Gtk.ResponseType.CANCEL, "打开", Gtk.ResponseType.OK))
        filt = Gtk.FileFilter()
        filt.set_name("图片")
        filt.add_pixbuf_formats()
        dialog.add_filter(filt)
        result = dialog.run()
        filename = dialog.get_filename() if result == Gtk.ResponseType.OK else None
        dialog.destroy()
        if filename:
            try:
                self.canvas.load(filename)
                self.set_title(f"图片裁剪设壁纸 — {Path(filename).name}")
            except Exception as exc:
                self.error(f"无法打开图片：{exc}")

    def apply_wallpaper(self, *_):
        if not self.canvas.pixbuf:
            self.error("请先选择一张图片。")
            return
        pictures = Path(GLib.get_user_special_dir(GLib.UserDirectory.DIRECTORY_PICTURES)
                        or (Path.home() / "Pictures"))
        out_dir = pictures / "裁剪壁纸"
        out_dir.mkdir(parents=True, exist_ok=True)
        output = out_dir / f"wallpaper_{datetime.now():%Y%m%d_%H%M%S}.png"
        try:
            self.canvas.crop(output)
            uri = output.resolve().as_uri()
            subprocess.run(["gsettings", "set", "org.gnome.desktop.background", "picture-uri", uri], check=True)
            subprocess.run(["gsettings", "set", "org.gnome.desktop.background", "picture-uri-dark", uri], check=True)
            subprocess.run(["gsettings", "set", "org.gnome.desktop.background", "picture-options", "zoom"], check=True)
            self.status.set_text(f"壁纸已设置：{output}")
            dialog = Gtk.MessageDialog(parent=self, flags=0, message_type=Gtk.MessageType.INFO,
                                       buttons=Gtk.ButtonsType.OK, text="壁纸设置成功")
            dialog.format_secondary_text(f"裁剪后的图片保存在：\n{output}")
            dialog.run()
            dialog.destroy()
        except Exception as exc:
            self.error(f"设置壁纸失败：{exc}")

    def restore_default_wallpaper(self, *_):
        dialog = Gtk.MessageDialog(
            parent=self, flags=0, message_type=Gtk.MessageType.QUESTION,
            buttons=Gtk.ButtonsType.OK_CANCEL, text="恢复系统默认壁纸？")
        dialog.format_secondary_text("这会重置 GNOME 的浅色、深色壁纸和显示方式，不会删除任何图片。")
        response = dialog.run()
        dialog.destroy()
        if response != Gtk.ResponseType.OK:
            return
        try:
            schema = "org.gnome.desktop.background"
            for key in ("picture-uri", "picture-uri-dark", "picture-options"):
                subprocess.run(["gsettings", "reset", schema, key], check=True)
            self.status.set_text("已恢复系统默认壁纸")
        except Exception as exc:
            self.error(f"恢复默认壁纸失败：{exc}")

    def error(self, message):
        dialog = Gtk.MessageDialog(parent=self, flags=0, message_type=Gtk.MessageType.ERROR,
                                   buttons=Gtk.ButtonsType.OK, text=message)
        dialog.run()
        dialog.destroy()


if __name__ == "__main__":
    app = App()
    app.show_all()
    if len(sys.argv) > 1 and os.path.isfile(sys.argv[1]):
        try:
            app.canvas.load(sys.argv[1])
        except Exception as exc:
            app.error(f"无法打开图片：{exc}")
    Gtk.main()
