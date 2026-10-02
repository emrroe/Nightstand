# Nightstand

A KOReader home screen backed by a [Calibre-Web-Automated](https://github.com/crocodilestick/Calibre-Web-Automated)
library. The server holds the shelf; the device holds a cache of it.

The whole library is on screen whether or not the file is here. Books that are
not on this device carry a download badge in the bottom-right corner of the
cover; tapping one fetches it and opens it. A continue-reading card reads its
position from CWA's KOSync endpoint, so it can name which device you last read
on.

## Status

The home screen works against a real CWA server: a continue-reading card,
then shelves of covers. The catalogue merges with the local folder,
server-only books carry a download badge, tapping one fetches it and opens
it, and covers are fetched once and kept on disk. The footer has Home,
Library and Settings; Library is not built yet.

## Hardcover

Connecting a [Hardcover](https://hardcover.app) account is optional and is
done per device under **Settings → Hardcover → Account**. Nightstand shows a
QR code and a short code; approve it on your phone at hardcover.app/link. No
password or token is ever typed on the reader, and the connection can be
revoked from Hardcover's connected-apps list or with **Disconnect** here.

## Install

Copy `nightstand.koplugin/` into KOReader's plugin folder:

| Platform | Folder |
|----------|--------|
| Linux desktop | `~/.config/koreader/plugins/` |
| Android | `/sdcard/koreader/plugins/` |
| Kobo, Kindle | `.adds/koreader/plugins/` |

Then set the server and books folder under **Tools → Nightstand**.

## Design

The layouts, the badge system and the comparison against other readers are
written up separately; the short version is that availability lives in one
corner of the cover and progress in another, nothing depends on colour, and
every screen is paged rather than scrolled.

## Credits

The download badge is derived from `cloud-arrow-down` in
[Font Awesome Free](https://fontawesome.com) 6.7.2, Copyright 2024 Fonticons,
Inc., licensed CC BY 4.0 and modified to carry a white outline. See
`nightstand.koplugin/resources/NOTICE.md`.

## Requires

KOReader 2026.07 or later.
