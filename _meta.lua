local _ = require("gettext")
return {
    -- Older KOReader plugin loaders read `name` from here; newer ones use the
    -- directory name.  Keeping both costs nothing.
    name = "ireader",
    fullname = _("iReader adaptation"),
    description = _([[
Native SmartOS "water ripple" page-turn animation for 掌阅 (iReader) e-ink
devices running SmartOS 4.x.

(Frontlight support is dormant: it would require root on the tested device.)
]]),
    version = "0.7.0",
}
