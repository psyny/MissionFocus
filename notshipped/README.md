# notshipped

Working files kept in the repository but left out of the packaged addon (`.pkgmeta` ignore) and out of release archives (`.gitattributes` export-ignore). Nothing here is loaded by the game.

## Addon icon

`logo.png` is the high-res logo. `python make_icon.py` (needs Pillow: `pip install pillow`) makes the in-game icon from it, `../Icons/logo.tga` (64x64), shown in the AddOns list (`## IconTexture` in the `.toc` files). The list shows it at about 20 px, so the script simplifies the logo; see the top of the script for how. Pass a file name (`python make_icon.py preview.png`) to also save an enlarged preview.
