# dmgbuild settings for the TajArchive disk image (used by Scripts/release.sh).
#
#   dmgbuild -s Scripts/dmg_settings.py -D app=path/to/TajArchive.app \
#            -D background=Scripts/assets/dmg-background.tiff \
#            -D volume_icon=Scripts/assets/VolumeIcon.icns "TajArchive 1.0.0" out.dmg
#
# The background (Scripts/make_dmg_background.swift) draws an arrow between the two
# icon positions below, so keep them in sync when changing the layout.
import os.path

app = defines["app"]
app_name = os.path.basename(app)

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
# No hide_extensions: it sets Finder info on the bundle, which breaks its code signature
# ("resource fork, Finder information, or similar detritus not allowed"). Finder hides
# ".app" on its own anyway.

icon = defines.get("volume_icon")
background = defines.get("background")

# Height includes Finder's 28 pt title bar, so the 400 pt background fits exactly.
window_rect = ((200, 120), (660, 428))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
icon_size = 128
text_size = 13
icon_locations = {
    app_name: (165, 180),
    "Applications": (495, 180),
}
