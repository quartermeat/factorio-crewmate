-- Runtime stage. The crewmate is a plain character entity with no player
-- attached; everything it does is driven from outside over RCON, through the
-- remote interface in script/api.lua.
require("script.body")
require("script.senses")
require("script.hands")
require("script.works")
require("script.plan")
require("script.api")
