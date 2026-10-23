# dmgbuild layout for Nano's DMG. build-release-dmg.sh passes
# -D app=<path> -D background=<path>.
# Icon centers match tools/dmg/render-background.swift.
import os.path

app = defines["app"]  # noqa: F821

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents", "Resources", "AppIcon.icns")
background = defines["background"]  # noqa: F821

# Finder counts the title bar in the height; the background is 640x420.
window_rect = ((200, 160), (640, 448))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
include_icon_view_settings = True

icon_size = 112
text_size = 13
arrange_by = None
label_pos = "bottom"
icon_locations = {
    os.path.basename(app): (180, 222),
    "Applications": (460, 222),
}
