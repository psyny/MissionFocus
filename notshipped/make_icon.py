"""
Makes the in-game addon icon (../Icons/logo.tga, 64x64) from the high-res logo
(logo.png, next to this script), for the AddOns list (## IconTexture in the .toc files).

The list shows the icon at about 20 px, so the logo is simplified: cropped to the
quest scroll with its "!" (the ring and the tray cards are mostly left out).

Usage:  python make_icon.py [preview_png]      (needs Pillow: pip install pillow)
"""
import os
import sys

from PIL import Image, ImageEnhance, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "Icons", "logo.tga")
CROP = (165, 215, 915, 965)   # square around the scroll, in logo.png pixels (1254x1254)


def finish(img):
    """Downscale to 64x64 and restore some contrast and edge sharpness lost in the shrink."""
    icon = img.resize((64, 64), Image.LANCZOS)
    icon = ImageEnhance.Contrast(icon).enhance(1.1)
    return icon.filter(ImageFilter.UnsharpMask(radius=1, percent=60, threshold=2))


def main():
    logo = Image.open(os.path.join(HERE, "logo.png")).convert("RGB")
    icon = finish(logo.crop(CROP)).convert("RGBA")
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    icon.save(OUT)
    print("wrote", os.path.normpath(OUT))
    if len(sys.argv) > 1:
        icon.resize((256, 256), Image.NEAREST).save(sys.argv[1])


if __name__ == "__main__":
    main()
