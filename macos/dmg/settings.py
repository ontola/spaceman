# dmgbuild settings for the SpaceMan installer window. tool/make_dmg.sh
# passes the app and the background with -D. The window size and icon
# positions match the background drawn by tool/generate_icons.dart.
import os.path

app = defines["app"]  # noqa: F821 (provided by dmgbuild)
app_name = os.path.basename(app)

files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents/Resources/AppIcon.icns")
background = defines["background"]  # noqa: F821

# LZFSE compression; opens on every macOS SpaceMan supports.
format = "ULFO"

window_rect = ((200, 120), (640, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
icon_locations = {app_name: (170, 190), "Applications": (470, 190)}
hide_extensions = [app_name]
