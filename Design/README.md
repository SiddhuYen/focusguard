# App icon

`make-app-icon.swift` draws the icon (a gate with one thing getting through) and writes a
PNG. To regenerate `Resources/AppIcon.icns`:

```sh
swiftc -O Design/make-app-icon.swift -o /tmp/makeicon
/tmp/makeicon /tmp/icon.png
mkdir -p /tmp/AppIcon.iconset
for pair in 16:icon_16x16 32:icon_16x16@2x 32:icon_32x32 64:icon_32x32@2x \
            128:icon_128x128 256:icon_128x128@2x 256:icon_256x256 \
            512:icon_256x256@2x 512:icon_512x512 1024:icon_512x512@2x; do
  px="${pair%%:*}"; name="${pair##*:}"
  sips -z "$px" "$px" /tmp/icon.png --out "/tmp/AppIcon.iconset/$name.png" > /dev/null
done
iconutil -c icns /tmp/AppIcon.iconset -o Resources/AppIcon.icns
```
