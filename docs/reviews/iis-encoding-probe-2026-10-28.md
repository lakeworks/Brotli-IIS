# IIS encoding choice for cached static files — probe record (2026-10-28)

Host: production IIS 10 (Windows Server 2025), schemes registered `br` (this plugin, brotli 1.2.1) then `gzip` (Microsoft `gzip.dll`); `staticCompressionIgnoreHitFrequency="true"`, `noCompressionForProxies="false"`. Requests made with `curl` from the server itself to each site's bound address over HTTPS; only the `Content-Encoding` response header was recorded. Site names omitted (public repository).

## Probe A — four never-requested static files on one WordPress site (~15:00 local)

Each file was requested five times in this order, each request's `Accept-Encoding` as listed:

| File | `gzip, deflate, br, zstd` | `gzip` | `gzip, deflate, br, zstd` | `br` | `gzip, deflate, br, zstd` |
|---|---|---|---|---|---|
| `wp-includes/css/buttons.min.css` | br | gzip | gzip | br | gzip |
| `wp-includes/css/editor.min.css` | br | gzip | gzip | br | gzip |
| `wp-includes/js/wp-embed.min.js` | br | gzip | **br** | br | **br** |
| `wp-includes/css/admin-bar.min.css` | br | gzip | gzip | br | gzip |

`wp-embed.min.js` is the smallest of the four; why it kept `br` was not investigated (possibly below `minFileSizeForComp`, so not served from the static cache).

## Probe B — a static file already served many times, another site on the same server (~06:20 local)

`wp-includes/css/dashicons.min.css`, no query string, each `Accept-Encoding` sent with and without `Via: BunnyCDN`:

| `Accept-Encoding` | Result |
|---|---|
| `br` | br |
| `br, gzip` | **gzip** |
| `zstd, br, gzip` | gzip |
| `gzip, br` | gzip |

In the same minute, `wp-includes/js/jquery/jquery.min.js` on that site answered `br` to `gzip, deflate, br, zstd`.

## Not established

Why IIS picks gzip in these cases, how long it persists, and what resets it (cache eviction, file change, worker restart) were not tested. Probe B contradicts a simple "first cached copy in the client's header order" rule.
