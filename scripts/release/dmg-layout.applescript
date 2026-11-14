-- Lays out a release's disk image window (docs/UPDATES.md D9), for pack-dmg.sh:
--
--   osascript dmg-layout.applescript <disk name> <app item name>
--
-- The window's inside is 660 × 440 points, the size of Packaging/DMG/WingcordBackground.tiff,
-- under a 32-point title bar: the app at 165, 205 and Applications at 495, 205, with the
-- background's arrow between them. Finder opens a window asynchronously, so it is waited for
-- before its view is set; and it shows the view options, and saves them, only once the window
-- is opened again.
on run argv
	set diskName to item 1 of argv
	set appItem to item 2 of argv
	tell application "Finder"
		tell disk diskName
			open
			repeat 50 times
				if exists container window then exit repeat
				delay 0.1
			end repeat
			delay 0.5
			set current view of container window to icon view
			set toolbar visible of container window to false
			set statusbar visible of container window to false
			set the bounds of container window to {200, 140, 860, 612}
			set viewOptions to the icon view options of container window
			set arrangement of viewOptions to not arranged
			set icon size of viewOptions to 128
			set text size of viewOptions to 13
			set background picture of viewOptions to file ".background:WingcordBackground.tiff"
			set position of item appItem of container window to {165, 205}
			set position of item "Applications" of container window to {495, 205}
			update without registering applications
			delay 1
			close container window
			delay 1
			open
			delay 1.5
			close container window
		end tell
	end tell
end run
