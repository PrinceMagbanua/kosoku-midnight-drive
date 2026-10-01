Kosoku Display is a modified version of Revalia
(Copyright (c) 2011, Johan Kallas, Mihkel Virkus - SIL Open Font License 1.1,
see OFL.txt), renamed as required by the license's Reserved Font Name clause.

Changes: vertical metrics only (glyphs untouched). Revalia's hhea descent was
stored with the wrong sign and its ascent left ~0.3 em of empty space above
the capitals, so Godot centred the line box well above the text and every
label/button looked pushed down. Ascent is now cap height + descent, so caps
sit centred in the line box. DSIG table dropped (invalid after editing).
