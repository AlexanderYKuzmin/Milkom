local async  = require("async")
local promise = require("promise")
local tagApi = require("simplight.api.channels")
local events = require("simp-events")
local log    = require("log")
local countDataPeriod = require("countDataPeriod")

local M = {}

local LOG_TAG = ""
local QUALITY_GOOD = 0xC0

-- В SimpLight 5.0 в async нет sleep — пауза через setInterval + promise.
local function sleepMs(ms)
  return promise:new(function(resolve)
    local timerId = setInterval(function()
      clearInterval(timerId)
      resolve()
    end, ms)
  end)
end

local CH_R = {
  START_MAIN  = "Дата_Начало",
  FINISH_MAIN = "Дата_Конец"
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

-- ==== Состояние ====
local warmup = true
local lastMainStart  = nil
local lastMainFinish = nil

-- lastWritten — только для отсечения эха собственной записи.
-- Храним { value, expireAt } — на случай, если эхо не придёт.
local lastWritten = {}
local LAST_WRITTEN_TTL_MS = 3000

local function nowMs()
  return os.time() * 1000
end

-- ==== Запись ====
local function writeManySafe(values, label, onDone)
  if not values or #values == 0 then
    if onDone then onDone(true) end
    return
  end

  local expireAt = nowMs() + LAST_WRITTEN_TTL_MS
  for _, v in ipairs(values) do
    lastWritten[v.name] = { value = v.value, expireAt = expireAt }
  end

  async(function()
    await(tagApi.writeMany({ values = values }))
    if onDone then onDone(true) end
  end):catch(function(err)
    log.warn(LOG_TAG, label .. " writeMany failed: " .. tostring(err))
    for _, v in ipairs(values) do
      local lw = lastWritten[v.name]
      if lw and lw.value == v.value then
        lastWritten[v.name] = nil
      end
    end
    if onDone then onDone(false) end
  end)
end

-- ==== Расчёт по расходомеру ====
local function runCounterCalc(counter, tStartOverride, tEndOverride)
  async(function()
    local tStart = tStartOverride
    local tEnd   = tEndOverride

    if tStart == nil or tEnd == nil then
      local tags = await(tagApi.readMany({ counter.startTag, counter.finishTag }))
      local sTag = tags and tags[1]
      local fTag = tags and tags[2]

      if not sTag or not fTag then
        log.warnF(LOG_TAG, "runCounterCalc(%d): не удалось прочитать даты", counter.n)
        return
      end
      if sTag.quality ~= QUALITY_GOOD or fTag.quality ~= QUALITY_GOOD then
        log.warnF(LOG_TAG, "runCounterCalc(%d): плохое качество дат", counter.n)
        return
      end

      tStart = tStart or tonumber(sTag.value)
      tEnd   = tEnd   or tonumber(fTag.value)
    end

    if tStart == nil or tEnd == nil then
      log.warnF(LOG_TAG, "runCounterCalc(%d): даты = nil", counter.n)
      return
    end
    if tEnd <= tStart then
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

local function runAllCounters(tStart, tEnd)
  for _, c in ipairs(COUNTERS) do
    runCounterCalc(c, tStart, tEnd)
  end
end

-- ==== Разнос общих дат по префиксным ====
local START_TAGS  = {}
local FINISH_TAGS = {}
for _, c in ipairs(COUNTERS) do
  START_TAGS[#START_TAGS + 1]   = c.startTag
  FINISH_TAGS[#FINISH_TAGS + 1] = c.finishTag
end

local function buildValues(list, value)
  local values = {}
  for _, tagName in ipairs(list) do
    values[#values + 1] = { name = tagName, value = value, quality = QUALITY_GOOD }
  end
  return values
end

local function writeStartTags(value)
  if value == nil then
    log.warn(LOG_TAG, "START: value=nil, пропуск записи")
    return
  end
  writeManySafe(buildValues(START_TAGS, value), "START", function(ok)
    if ok then runAllCounters(value, nil)
    else log.warn(LOG_TAG, "START: пропускаем расчёт") end
  end)
end

local function writeFinishTags(value)
  if value == nil then
    log.warn(LOG_TAG, "FINISH: value=nil, пропуск записи")
    return
  end
  writeManySafe(buildValues(FINISH_TAGS, value), "FINISH", function(ok)
    if ok then runAllCounters(nil, value)
    else log.warn(LOG_TAG, "FINISH: пропускаем расчёт") end
  end)
end

-- ==== Обработка локальной даты ====
local function handleLocalDateChange(change)
  local name = change.name
  local counter = counterByStartTag[name] or counterByFinishTag[name]
  if not counter then
    return false
  end

  -- отсечь эхо собственной записи (с учётом TTL)
  local lw = lastWritten[name]
  if lw then
    if nowMs() <= lw.expireAt and lw.value == change.value then
      lastWritten[name] = nil
      return true
    end
    if nowMs() > lw.expireAt then
      lastWritten[name] = nil
    end
  end

  local v = tonumber(change.value)
  if v == nil then
    log.warnF(LOG_TAG, "Изменена локальная дата %s, но value=nil", name)
    return true
  end

  log.infoF(LOG_TAG, "Изменена локальная дата %s, пересчёт расходомера %d", name, counter.n)

  if name == counter.startTag then
    runCounterCalc(counter, v, nil)
  else
    runCounterCalc(counter, nil, v)
  end
  return true
end

-- ==== Старт/стоп ====
local handler

function M.start()
  warmup = true

  async(function()
    local res = await(tagApi.readMany({ CH_R.START_MAIN, CH_R.FINISH_MAIN }))
    local s = res and res[1] and tonumber(res[1].value)
    local f = res and res[2] and tonumber(res[2].value)
    lastMainStart  = s
    lastMainFinish = f
    log.infoF(LOG_TAG, "init: Дата_Начало=%s, Дата_Конец=%s",
      tostring(s), tostring(f))

    -- дать платформе выдать весь «залп» стартовых channelChanges
    await(sleepMs(1000))
    warmup = false
    log.info(LOG_TAG, "warmup завершён")
  end):catch(function(err)
    log.warn(LOG_TAG, "init error: " .. tostring(err))
    warmup = false
  end)

  handler = function(event)
    for _, c in ipairs(event.changes or {}) do
      if warmup then
        goto continue
      end

      if c.name == CH_R.START_MAIN then
        local v = tonumber(c.value)
        if v == nil then
          log.warn(LOG_TAG, "START: value=nil, пропуск")
        elseif lastMainStart == v then
          -- дубль
        else
          lastMainStart = v
          writeStartTags(v)
        end
      elseif c.name == CH_R.FINISH_MAIN then
        local v = tonumber(c.value)
        if v == nil then
          log.warn(LOG_TAG, "FINISH: value=nil, пропуск")
        elseif lastMainFinish == v then
          -- дубль
        else
          lastMainFinish = v
          writeFinishTags(v)
        end
      else
        handleLocalDateChange(c)
      end

      ::continue::
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