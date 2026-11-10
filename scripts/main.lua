local logger = require("logger")
logger.info("main", "=== СТАРТ СКРИПТОВ ===")

local stateHandling = require("stateHandling")
local dateHandler = require("dateHandler")

--stateHandling.start()
dateHandler.start()
