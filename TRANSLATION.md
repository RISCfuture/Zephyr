# Translating Zephyr

Guidance for anyone, human or agent, translating Zephyr's interface, Help book or App Store
listing. Where it conflicts with Apple's per-locale style guide, this file wins; where it is
silent, the style guide does.

## Locales

| Locale | Language | App Store folder |
| --- | --- | --- |
| `de` | German | `de-DE` |
| `fr` | French | `fr-FR` |
| `es` | Spanish (Spain) | `es-ES` |

## Who reads it

Mac users who already know Dropbox and Finder in their own language. Zephyr lives inside
Finder and the menu bar, so it should read as part of macOS: use the words macOS and Dropbox
already use for the same things, and never coin a new one where they have one.

## Never translate

- **Names:** Zephyr, Dropbox and Dropbox, Inc., Finder, macOS, System Settings' own pane names
  as macOS shows them, File Provider, Maestral.
- **Protocol and API terms** in error details: HTTP, PKCE, `Dropbox-API-Result`, route names
  such as `files/list_folder`, status codes.
- **Paths and commands:** `/usr/local/bin`, the `zephyr` command and its arguments.
- **Developer-facing fragments** that are interpolated into a larger error (“malformed path”,
  “file metadata had no path”) are translated, but keep any identifier inside them verbatim.

## Terms

Match macOS's own localization first, then Dropbox's. Where neither settles it, use the table;
once a term is chosen for a locale, every string, the Help book and the App Store listing use it.

| English | Meaning | de | fr | es |
| --- | --- | --- | --- | --- |
| sync, syncing | keeping the Dropbox and the Mac in step | synchronisieren, Synchronisierung | synchroniser, synchronisation | sincronizar, sincronización |
| link, unlink (an account) | authorize or remove a Dropbox account | verknüpfen, Verknüpfung aufheben | associer, dissocier | vincular, desvincular |
| shared link, share link | a Dropbox link anyone can open | geteilter Link, Link kopieren (Dropbox) | lien partagé, Copier le lien (Dropbox) | enlace compartido, Copiar enlace (Dropbox) |
| kept downloaded | a file pinned so it stays on disk; Finder's “Keep Downloaded” | Laden und behalten (Finder), geladen und behalten | Conserver le téléchargement, Téléchargement conservé (Finder) | Conservar en dispositivo (Finder), conservado en el dispositivo |
| index, rebuild the index | Zephyr's local database of the Dropbox's contents | Index, Index neu erstellen | index, reconstruire l’index | índice, reconstruir el índice |
| pause, resume (syncing) | stop and restart transfers | anhalten, fortsetzen | suspendre, reprendre | pausar, reanudar |
| transfer limit, upload limit, download limit | bandwidth caps | Übertragungslimit, Upload-Limit, Download-Limit; begrenzen | limite de débit, limite de transfert, limite de téléchargement ; limiter | límite de transferencia, límite de carga, límite de descarga; limitar |
| metered network | a connection macOS marks as expensive or constrained | getaktetes Netzwerk; teuer (macOS), Datensparmodus | réseau facturé à l’usage ; coûteux (macOS), mode Faibles données | red de uso medido; de precio elevado (macOS), modo de datos reducidos |
| notification, notifications | an alert Zephyr posts; the System Settings pane | Mitteilung, Mitteilungen | notification, notifications | notificación, notificaciones |
| snooze (notifications) | silence notifications for a set time | Mitteilungen stummschalten, Stummschaltung, stummgeschaltet bis | masquer les notifications, masquées jusqu’à | silenciar las notificaciones, silenciadas hasta |
| sync issues | items that couldn't be synced | Synchronisierungsprobleme | problèmes de synchronisation | problemas de sincronización |

A dash means no term has been decided. Decide it before the first translation batch for that
locale, write it into this table, and use it from then on. “Finder's term” and “Dropbox's own
term” mean the wording those products ship in that language; look it up rather than guess.

## Style

- **Buttons and menu items** are verbs; **labels and headers** are nouns. Read the call site.
- **Strings that name another control** (“Open Notifications”, “Enable Zephyr in Finder”)
  must use that control's translated title, including macOS's own titles for System Settings.
- **Ellipsis:** keep a trailing “…” wherever the source has one.
- **Activity strings** (“%1$@ added “%2$@”.”) put a person or device first and a file name
  second; reorder freely with positional specifiers, but keep every specifier.
- **Durations** (“30 min”, “1 hr”, “8 hours”) are menu items; use the language's standard
  abbreviations and plural forms.
- **Error messages** follow the project's `LocalizedError` shape: `errorDescription` is a
  general statement, `failureReason` the specifics. Keep each a complete sentence.
- **The non-affiliation notice** (“not affiliated with, endorsed by, or sponsored by Dropbox”)
  is translated faithfully and in full, wherever it appears.
- **“Your Dropbox”**, the user's folder and account, is masculine in French and Spanish, as
  Dropbox's own interface has it (« votre Dropbox est plein », “tu Dropbox está lleno”).
  Dropbox the service takes no article.

## Help book

`Help/Zephyr.help/Contents/Resources/en.lproj/` is the source. A translation is a sibling
`<locale>.lproj/` folder with every page, the same file names, the same `<a name="…">` anchors
and the same `<meta name="robots" content="index, anchor">` tags; `build-help-book.sh` indexes
each `.lproj` it finds. Translate text, `<title>` and `alt` attributes; leave markup, class
names, anchors and `href`s alone. Until screenshots are captured in that language, point each
`images/…` reference at `../en.lproj/images/…`.

## App Store listing

`fastlane/metadata/en-US/` is the source; each locale gets its own folder named as in the
locale table. Translate the text files; copy URL files unchanged. App Store limits: name and
subtitle 30 characters, promotional text 170, keywords 100 bytes as a comma-separated list
with no spaces after commas, description 4,000. Keywords are search terms people in that
market type, not a translation of the English list. `promo/copy.en-US.json` holds the
screenshot captions; each locale gets a `copy.<App Store folder>.json`, with each line short
enough for the caption it replaces.
