# CoverLab

A KOReader plugin to discover, compare, import and restore EPUB covers. Books remain unchanged; covers use KOReader's existing custom-cover sidecars.

**Development version 0.1.0.** Tested with the official KOReader v2026.07.1 Linux desktop distribution. Physical Kindle acceptance testing is still required.

## Install

Copy `coverlab.koplugin` into KOReader's `plugins` directory and restart KOReader. Open **CoverLab** from the reader tools menu, the file browser tools menu, or an EPUB's long-press menu.

To create an installable ZIP:

```sh
python3 tools/build.py
```

## Sources

**Amazon Kindle is the primary source.** CoverLab searches public Amazon.com Kindle pages on demand, identifies Kindle ASINs, and requests the original CDN artwork rather than enlarged search thumbnails. A known Kindle ASIN is looked up first. You can edit the title, author, ISBN and ASIN without modifying book metadata.

**Open Library is the secondary source.** It is enabled by default as a fallback when Amazon returns no candidates or is unavailable. You can also select **Search Open Library** from Amazon's results. Turn it off in **CoverLab → Settings → Open Library fallback: Off**. Disabled means CoverLab does not invoke the Open Library provider, including its cached search path or thumbnails.

Amazon search results are title/author matches, not verified ISBN editions. Only a matching Kindle ASIN is labelled exact. Open Library exact matches use edition-level ISBN data. Edition confidence ranks ahead of image quality.

Amazon pages can change or return access blocks. CoverLab stops on CAPTCHA, blocking, or unsupported markup; it does not log in or attempt to bypass access controls. Local JPEG/PNG selection and direct HTTPS image URLs remain available. No API key, account or companion server is required.

## Changing and restoring covers

1. Find a cover or choose a local image/direct HTTPS URL.
2. Inspect its resolution, aspect ratio, source and edition in the preview. Full-screen viewing is available.
3. Tap **Apply Cover** and confirm.

**Restore Previous Custom Cover** returns to the cover active before the last change. **Use Original Book Cover** removes custom overrides and preserves the formerly active custom cover for restoration. These operations do not change progress, bookmarks, highlights, annotations or EPUB bytes. Overrides apply only inside KOReader.

Replacement stages the image and previous-cover records and verifies backups before touching active covers. A journal supports rollback after failed writes and recovery when the book is reopened after an interruption. Originals are temporarily renamed beside their original paths, so rollback does not require space for another image copy. Recovery backups remain until the journal is successfully removed. Persistent backups live in a `coverlab` subdirectory of the actual sidecar location obtained from `DocSettings`, including centralized and hashed storage. Keep that subdirectory with the sidecar when moving a book.

## Limits and preferences

- Downloads default to 10 MB; adjustable from 1–20 MB.
- JPEG/PNG dimensions are capped at 10,000 pixels per side and 12 megapixels to limit decoder memory.
- Searches and thumbnails are cached for seven days by default; the cache is bounded to 40 MB on startup.
- The gallery uses at most six candidates per page and fewer on smaller screens. Original dimensions come from a bounded image-header request and are verified by full decoding before application.
- Network work runs in cancellable KOReader subprocesses. Tap the progress dialog to cancel.
- HTTPS certificates and names are verified. Each redirect is checked; private/reserved addresses and credentials in URLs are rejected. Connections are pinned to a validated public IPv4 address. IPv6-only hosts and HTTP proxies are currently unsupported.
- Requests are serial and separated by at least 1.1 seconds. Rate-limit responses set a retry cooldown for that destination host; other providers and unrelated image imports remain available.
- An optional Open Library contact email can be configured in download/cache settings.

## Development and validation

```sh
luajit tests/run.lua
```

The standalone tests simulate KOReader interfaces. Native integration tests use the real document providers, image decoders, dialogs and sidecar APIs:

```sh
python3 tests/make_fixture.py /tmp/coverlab-fixtures
```

From an extracted official KOReader Linux distribution's `lib/koreader` directory:

```sh
KO_HOME=/tmp/coverlab-test SDL_VIDEODRIVER=dummy ./luajit \
    /path/to/CoverLab/tests/native.lua \
    /path/to/CoverLab/coverlab.koplugin /tmp/coverlab-fixtures
```

Native checks cover cover replacement and restoration in all three sidecar storage modes, simulated full-storage rollback, unchanged EPUB bytes, dialog layout and pagination. Add `COVERLAB_LIVE_TEST=1` for a live Amazon lookup and original-image download. Physical Kindle acceptance testing remains required.
