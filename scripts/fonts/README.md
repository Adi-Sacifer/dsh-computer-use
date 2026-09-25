# Bundled fonts

Two blackletter faces, used only for the optional takeover overlay's Latin subtitle. Nothing is
installed system-wide; `fx.ps1` loads them straight from this folder as
`file:///.../Name.ttf#FamilyName`.

| File | Family | Copyright |
|---|---|---|
| `UnifrakturCook-Bold.ttf` | UnifrakturCook | © 2010 j. 'mach' wust, © 2009 Peter Wiegel |
| `UnifrakturMaguntia-Book.ttf` | UnifrakturMaguntia | © 2010 j. 'mach' wust, © 2009 Peter Wiegel |

Both are licensed under the **SIL Open Font License, Version 1.1** — the full text is in
[`OFL.txt`](OFL.txt), extracted verbatim from the font's own `name` table rather than retyped.
Both carry Reserved Font Names (`UnifrakturCook`, `UnifrakturMaguntia`), so if you modify and
redistribute them, rename them.

## Do you need these?

No. Delete this whole folder and the overlay falls back to a system font (`Georgia` by default, or
whatever you pass as `-SubFont`). The toolkit never depends on them.
