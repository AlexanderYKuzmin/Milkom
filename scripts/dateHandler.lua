local async  = require("async")
local tagApi = require("simplight.api.channels")
local events = require("simp-events")
local log    = require("log")

local M = {}

local LOG_TAG = ""

local QUALITY_GOOD = 0xC0

local CH_R = {
  START_MAIN  = "Дата_Начало",
  FINISH_MAIN = "Дата_Конец"
}

local CH_W_START = {
  START_1  = "1_Дата_Начало",
  START_2  = "2_Дата_Начало",
  START_3  = "3_Дата_Начало",
  START_4  = "4_Дата_Начало",
  START_5  = "5_Дата_Начало",
  START_6  = "6_Дата_Начало",
  START_7  = "7_Дата_Начало",
  START_22 = "22_Дата_Начало",
}

local CH_W_FINISH = {
  FINISH_1  = "1_Дата_Конец",
  FINISH_2  = "2_Дата_Конец",
  FINISH_3  = "3_Дата_Конец",
  FINISH_4  = "4_Дата_Конец",
  FINISH_5  = "5_Дата_Конец",
  FINISH_6  = "6_Дата_Конец",
  FINISH_7  = "7_Дата_Конец",
  FINISH_22 = "22_Дата_Конец"
}

-- Собирает список { name, value, quality } из таблицы "номер -> имя тега"
local function buildValues(tagMap, value)
  local values = {}
  for _, tagName in pairs(tagMap) do
    values[#values + 1] = {
      name    = tagName,
      value   = value,
      quality = QUALITY_GOOD
    }
  end
  return values
end

-- Записывает набор значений через writeMany с обработкой ошибок
local function writeManySafe(values, label)
  async(function()
    await(tagApi.writeMany({ values = values }))
  end):catch(function(err)
    log.warn(LOG_TAG, label .. " writeMany failed: " .. tostring(err))
  end)
end

-- Запись значения во все теги "*_Дата_Начало"
local function writeStartTags(value)
  writeManySafe(buildValues(CH_W_START, value), "START")
end

-- Запись значения во все теги "*_Дата_Конец"
local function writeFinishTags(value)
  writeManySafe(buildValues(CH_W_FINISH, value), "FINISH")
end

local handler

function M.start()
  handler = function(event)
    for _, c in ipairs(event.changes or {}) do
      if c.name == CH_R.START_MAIN then
        writeStartTags(c.value)
      elseif c.name == CH_R.FINISH_MAIN then
        writeFinishTags(c.value)
      end
    end
  end

  events.on("channelChanges", handler)
end

function M.stop()
  if handler then
    events.off("channelChanges", handler)
    handler = nil
  end
end

return M