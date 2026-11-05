local async  = require("async")
local tagApi = require("simplight.api.channels")
local events = require("simp-events")
local log    = require("log")
local countDataPeriod = require("countDataPeriod")

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

local COUNTERS = {
  { n = 1,  fm = "FM-1"  },
  { n = 2,  fm = "FM-2"  },
  { n = 3,  fm = "FM-3"  },
  { n = 4,  fm = "FM-4"  },
  { n = 5,  fm = "FM-5"  },
  { n = 6,  fm = "FM-6"  },
  { n = 7,  fm = "FM-7"  },
  { n = 22, fm = "FM-22" },
}

local counterByStartTag  = {}
local counterByFinishTag = {}

for _, c in ipairs(COUNTERS) do
  local prefix = c.n .. "_"
  c.startTag       = prefix .. "Дата_Начало"
  c.finishTag      = prefix .. "Дата_Конец"
  c.source         = "Тв_цех." .. c.fm .. ".Reg_R.SCo_Расход"
  c.volumeSource   = "Тв_цех." .. c.fm .. ".Reg_R.SCo_Объем"
  c.avgTag         = prefix .. "Ср_расх_период"
  c.maxTag         = prefix .. "Макс_расх_период"
  c.minTag         = prefix .. "Мин_расх_период"
  c.consumptionTag = prefix .. "Потребление_период"

  counterByStartTag[c.startTag]   = c
  counterByFinishTag[c.finishTag] = c
end

-- Метки «эха» собственной записи.
-- Нужны не для гонки с пользователем (общие и локальные даты на разных экранах,
-- пользователь не успеет), а чтобы writeMany не порождал повторный расчёт
-- через channelChanges по тем же локальным датам.
local lastWritten = {}

local function buildValues(tagMap, value)
  local values = {}
  for _, tagName in pairs(tagMap) do
    values[#values + 1] = { name = tagName, value = value, quality = QUALITY_GOOD }
  end
  return values
end

local function writeManySafe(values, label, onDone)
  for _, v in ipairs(values) do
    lastWritten[v.name] = v.value
  end

  async(function()
    await(tagApi.writeMany({ values = values }))
    if onDone then onDone(true) end
  end):catch(function(err)
    log.warn(LOG_TAG, label .. " writeMany failed: " .. tostring(err))
    for _, v in ipairs(values) do
      if lastWritten[v.name] == v.value then
        lastWritten[v.name] = nil
      end
    end
    if onDone then onDone(false) end
  end)
end

local function runCounterCalc(counter)
  async(function()
    local tags = await(tagApi.readMany({ counter.startTag, counter.finishTag }))
    local startTag  = tags and tags[1]
    local finishTag = tags and tags[2]

    if not startTag or not finishTag then
      log.warnF(LOG_TAG, "runCounterCalc(%d): не удалось прочитать даты", counter.n)
      return
    end
    if startTag.quality ~= QUALITY_GOOD or finishTag.quality ~= QUALITY_GOOD then
      log.warnF(LOG_TAG, "runCounterCalc(%d): плохое качество дат", counter.n)
      return
    end

    local tStart = tonumber(startTag.value)
    local tEnd   = tonumber(finishTag.value)
    if tStart == nil or tEnd == nil or tEnd <= tStart then
      log.warnF(LOG_TAG, "runCounterCalc(%d): некорректный период %s..%s",
        counter.n, tostring(tStart), tostring(tEnd))
      return
    end

    countDataPeriod.countDataPeriod({
      source         = counter.source,
      volumeSource   = counter.volumeSource,
      avgTag         = counter.avgTag,
      maxTag         = counter.maxTag,
      minTag         = counter.minTag,
      consumptionTag = counter.consumptionTag,
      period         = { start = tStart, finish = tEnd },
    })
  end):catch(function(err)
    log.warn(LOG_TAG, "runCounterCalc(" .. counter.n .. ") error: " .. tostring(err))
  end)
end

local function runAllCounters()
  for _, c in ipairs(COUNTERS) do
    runCounterCalc(c)
  end
end

local function writeStartTags(value)
  writeManySafe(buildValues(CH_W_START, value), "START", function(ok)
    if ok then runAllCounters()
    else log.warn(LOG_TAG, "START: пропускаем расчёт, запись дат не удалась") end
  end)
end

local function writeFinishTags(value)
  writeManySafe(buildValues(CH_W_FINISH, value), "FINISH", function(ok)
    if ok then runAllCounters()
    else log.warn(LOG_TAG, "FINISH: пропускаем расчёт, запись дат не удалась") end
  end)
end

-- Локальная дата: эхо собственной записи -> пропуск, иначе -> пересчёт одного расходомера
local function handleLocalDateChange(change)
  local name = change.name
  local counter = counterByStartTag[name] or counterByFinishTag[name]
  if not counter then
    return false
  end

  if lastWritten[name] ~= nil and lastWritten[name] == change.value then
    lastWritten[name] = nil
    return true  -- это наше эхо от writeMany
  end

  log.infoF(LOG_TAG, "Изменена локальная дата %s, пересчёт расходомера %d",
    name, counter.n)
  runCounterCalc(counter)
  return true
end

local handler

function M.start()
  handler = function(event)
    for _, c in ipairs(event.changes or {}) do
      if c.name == CH_R.START_MAIN then
        writeStartTags(c.value)
      elseif c.name == CH_R.FINISH_MAIN then
        writeFinishTags(c.value)
      else
        handleLocalDateChange(c)
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