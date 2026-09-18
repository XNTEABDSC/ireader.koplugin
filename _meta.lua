local _ = require("gettext")
return {
    -- Older KOReader plugin loaders read `name` from here; newer ones use the
    -- directory name.  Keeping both costs nothing.
    name = "ireader",
    fullname = _("iReader adaptation"),
    description = _([[
Hardware adaptation for 掌阅 (iReader) e-ink devices running SmartOS 4.x:

* Frontlight control through the device's own LED/sysfs interface.
* Native SmartOS "water ripple" page-turn animation (EPDC).
]]),
    version = "0.5.0",
}
