# macOS localization contract

Modore ships Korean, English, and Japanese catalogs. Regional tags resolve to the
base language. Preferred languages are considered in order; when none are
supported, English is used. This is an English fallback, not a claim to translate
every language. The currently shipped content is left-to-right, including when
macOS itself uses a right-to-left language.

User-visible native strings use `L10n.text` or `L10n.format`. Keep all three
`Localizable.strings` catalogs in sync. Format arguments must retain their ABI
types and semantic order. Dates and measured quantities use the current locale.
Use count labels when a sentence would require language-specific plural rules.

`L10n.message` is a presentation adapter for known Modore diagnostics and legacy
backend messages. It must not be used on conversation content, paths, project
names, or identifiers. Unknown external messages remain verbatim. Transaction
warnings, state comparisons, and target revalidation retain their original
protocol values; translated UI must never change an approval fingerprint.

The native HTML renderer receives the selected language and report fragments
from the app. Source-checkout reports load the corresponding report JSON catalog.
Only static markup is localized; interpolated scan values are preserved. Python
reports use `PCH_LANG`, `LC_ALL`, `LC_MESSAGES`, then `LANG`, and fall back to English.

Regression checks:

- `swift test --package-path macos/Modore -j 2`
- `python3 -m pytest tests/test_macos_localization.py tests/test_report_language_fallback.py tests/test_report.py tests/test_a11y_reports.py -q`

The catalog audit runs in the regular Python CI suite. It rejects missing native
keys, unequal language key sets, incompatible format arguments, and newly exposed
Korean view literals outside the localization path. The native report test also
checks that a Korean computer name remains unchanged in English and Japanese.
