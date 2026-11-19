# dmgbuild settings for the Unified Slicer DMG: a fixed Finder window with the app on the
# left, an Applications shortcut on the right and an arrow between them (background.png,
# with background@2x.png picked up for Retina screens).
#
#   dmgbuild -s scripts/dmg/settings.py -D app="path/to/Unified Slicer.app" \
#            -D background=scripts/dmg/background.png "Unified Slicer" out.dmg
import os

app = defines["app"]
app_name = os.path.basename(app)

format = "UDZO"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents", "Resources", "Icon.icns")
if not os.path.isfile(icon):
    icon = None

background = defines["background"]
window_rect = ((200, 120), (640, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 112
text_size = 13
icon_locations = {
    app_name: (160, 190),
    "Applications": (480, 190),
}
