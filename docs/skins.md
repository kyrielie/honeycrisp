# Reader skins

Honeycrisp reads `.nnwtheme` bundles from the app's `Bundled` resources and from `~/Library/Application Support/Honeycrisp/Skins`. Install a folder from Settings > Appearance or import a ZIP archive. No network access is used.

## Bundle files

Each bundle contains:

- `Info.plist` with `Name`, `ThemeIdentifier`, optional `CreatorName`, `Version`, `Family`, `FamilyVariant`, and license metadata.
- `stylesheet.css` with at most 160 KB.
- `template.html` with at most 16 KB.
- Optional `License.md`, `LICENSE`, or `NOTICE`.

Templates are sanitized and use a fixed macro set: `[[body]]`, `[[byline]]`, `[[title]]`, `[[preferred_link]]`, `[[text_size_class]]`, `[[feed_link]]`, `[[feed_link_title]]`, `[[date_medium]]`, `[[datetime_long]]`, `[[dateline_style]]`, `[[datetime_medium]]`, `[[external_link]]`, `[[external_link_label]]`, `[[external_link_stripped]]`, `[[time_medium]]`, `[[time_long]]`, and `[[avatar_src]]`. A valid template includes `id="bodyContainer"`, an `articleBody` class and `[[body]]`. Scripts, event handlers, active embeds, remote URLs and unsupported macros are rejected or removed. The avatar macro resolves to a transparent local image.

## Colors and CSS

Color tokens are optional. When present, `:root` defines literal `--nnw-bg`, `--nnw-ink` and `--nnw-link` values using `#RGB` or `#RRGGBB`. A dark `:root` inside `prefers-color-scheme: dark` supplies dark values; without it, light tokens are used in both modes. `--nnw-bg` colors the page canvas as well as the article background. For older tokenless skins, Honeycrisp infers a palette only when simple `body { background-color; color; }` and `a { color; }` rules provide all three literal hex colors; other tokenless skins use Honeycrisp defaults. Ink contrast below 4.5:1 is shown as a warning; below 1.5:1 is rejected.

AO3 gallery styles that target `#ao3Preface` also match AO3's original `#preface` container, so their preface treatments work when the replacement-preface setting is off.

Leading font imports are recorded for display but are not downloaded. Relative and fragment URLs are allowed; remote and unsupported URLs are rejected. The `[[font-size]]` macro is replaced with `16`. Skins cannot set reader scrolling or pagination geometry. In paginated mode, Honeycrisp owns page-column width and margins. A global max-width override also clears a skin's body max-width in scroll mode.

Skin CSS is composed after Honeycrisp's baseline reader CSS. The baseline presentational reset uses zero-specificity `:where(#bodyContainer *)`, allowing skin declarations to win. Global reader overrides apply last. EPUB-supplied stylesheets are never loaded.
