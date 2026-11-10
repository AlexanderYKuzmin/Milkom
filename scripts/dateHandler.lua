-- dateHandler.lua
-- Изменение общей даты (Дата_Начало / Дата_Конец) ->
-- последовательный расчёт по всем расходомерам ->
-- запись в теги N_Ср_расх_период, N_Макс_расх_период,
-- N_Мин_расх_период, N_Потребление_период.
local async      = require("async")
local promise    = require("promise")
local tagApi     = require("simplight.api.channels")
local events     = require("simp-events")
local momentApi  = require("moments")
local logger     = require("logger")

local M = {}

local LOG_TAG = "dateHandler"
local QUALITY_GOOD = 0xC0

-- sleep через setInterval + promise (в Simplight 5.0 в async нет sleep)
local function sleepMs(ms)
  return promise:new(function(resolve)
    local timerId = setInterval(function()
      clearInterval(timerId)
      resolve()
    end, ms)
  end)
end

local function toNum(v)
  if v == nil then return nil end
  return tonumber(v)
end

local function toMs(v)
  return toNum(v)  -- datetime в Simplight приходит числом мс
end

-- ==== Общие даты ====
local CH_R = {
  START_MAIN  = "Дата_Начало",
  FINISH_MAIN = "Дата_Конец"
}

-- ==== Расходомеры ====
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

for _, c in ipairs(COUNTERS) do
  local prefix = c.n .. "_"
  c.source         = "Тв_цех." .. c.fm .. ".Reg_R.SCo_Расход"
  c.volumeSource   = "Тв_цех." .. c.fm .. ".Reg_R.SCo_Объем"
  c.avgTag         = prefix .. "Ср_расх_период"
  c.maxTag         = prefix .. "Макс_расх_период"
  c.minTag         = prefix .. "Мин_расх_период"
  c.consumptionTag = prefix .. "Потребление_период"
end

-- ==== Состояние ====
local warmup = true
local lastMainStart  = nil
local lastMainFinish = nil
local inProgress = false

-- ==== Один проход по одному расходомеру ====
-- Полноценная async-функция (возвращает промис).
-- Внутри — только await, как в oct_report_data_period.
local function calcOneCounter(counter, tStart, tEnd)
  return async(function()
    local optsFlow = {
      channelName = counter.source,
      start = tStart,
      ending = tEnd,
    }

    local avg  = await(momentApi.getAverage(optsFlow))
    local maxV = await(momentApi.getMax(optsFlow))
    local minV = await(momentApi.getMin(optsFlow))

    if avg == nil then
      logger.warnF(LOG_TAG, "counter=%d: no avg data for %s", counter.n, counter.source)
    end
    if maxV == nil then
      logger.warnF(LOG_TAG, "counter=%d: no max data for %s", counter.n, counter.source)
    end
    if minV == nil then
      logger.warnF(LOG_TAG, "counter=%d: no min data for %s", counter.n, counter.source)
    end

    -- Потребление по объёму
    local consumption
    if counter.volumeSource and counter.consumptionTag then
      local optsVol = { channelName = counter.volumeSource, start = tStart, ending = tEnd }
      local vMin = await(momentApi.getMin(optsVol))
      local vMax = await(momentApi.getMax(optsVol))
      if vMin ~= nil and vMax ~= nil then
        local a, b = toNum(vMin), toNum(vMax)
        if a ~= nil and b ~= nil then
          consumption = b - a
          if consumption < 0 then
            logger.warnF(LOG_TAG,
              "counter=%d: negative consumption (%s) for %s, set 0",
              counter.n, tostring(consumption), counter.volumeSource)
            consumption = 0
          end
        end
      else
        logger.warnF(LOG_TAG, "counter=%d: no volume data for %s",
          counter.n, counter.volumeSource)
      end
    end

    -- Собираем значения для записи
    local values = {}
    if counter.avgTag and avg ~= nil then
      values[#values + 1] = { name = counter.avgTag, value = avg, quality = QUALITY_GOOD }
    end
    if counter.maxTag and maxV ~= nil then
      values[#values + 1] = { name = counter.maxTag, value = maxV, quality = QUALITY_GOOD }
    end
    if counter.minTag and minV ~= nil then
      values[#values + 1] = { name = counter.minTag, value = minV, quality = QUALITY_GOOD }
    end
    if counter.consumptionTag and consumption ~= nil then
      values[#values + 1] = { name = counter.consumptionTag, value = consumption, quality = QUALITY_GOOD }
    end

    logger.infoF(LOG_TAG,
      "counter=%d: avg=%s max=%s min=%s cons=%s, write %d tag(s)",
      counter.n, tostring(avg), tostring(maxV), tostring(minV), tostring(consumption), #values)

    if #values > 0 then
      await(tagApi.writeMany({ values = values }))
      logger.infoF(LOG_TAG, "counter=%d: writeMany OK (%d tag(s))", counter.n, #values)
    else
      logger.warnF(LOG_TAG, "counter=%d: nothing to write", counter.n)
    end
  end)
end

-- ==== Обработка изменения общей даты ====
-- Одна async-функция на всё изменение. Внутри — последовательный цикл
-- с await(calcOneCounter(...)). Каждый calcOneCounter — свой async.
local function onMainDateChanged()
  if inProgress then
    logger.info(LOG_TAG, "calc already in progress, skip")
    return
  end
  inProgress = true

  async(function()
    -- 1) читаем обе даты одним readMany
    local res = await(tagApi.readMany({ CH_R.START_MAIN, CH_R.FINISH_MAIN }))
    local sTag = res and res[1]
    local fTag = res and res[2]
    local s = sTag and toMs(sTag.value)
    local f = fTag and toMs(fTag.value)

    logger.infoF(LOG_TAG, "readMainDates: start=%s, finish=%s", tostring(s), tostring(f))

    if s == nil or f == nil then
      logger.warn(LOG_TAG, "one of dates is nil, skip")
      return
    end
    if s == lastMainStart and f == lastMainFinish then
      logger.info(LOG_TAG, "dates unchanged, skip")
      return
    end
    lastMainStart  = s
    lastMainFinish = f

    if f <= s then
      logger.warnF(LOG_TAG, "finish <= start (%s..%s), skip", tostring(s), tostring(f))
      return
    end

    logger.infoF(LOG_TAG, "period updated: %s..%s", tostring(s), tostring(f))

    -- 2) последовательный расчёт по всем расходомерам
    for _, c in ipairs(COUNTERS) do
      logger.infoF(LOG_TAG, "runCounterCalc(%d): %s..%s", c.n, tostring(s), tostring(f))
      await(calcOneCounter(c, s, f))
    end

    logger.info(LOG_TAG, "all counters processed")
  end):catch(function(err)
    local msg = tostring(err)
    if msg:find("context canceled", 1, true) then
      logger.warn(LOG_TAG, "onMainDateChanged: cancelled by reload")
    else
      logger.warnF(LOG_TAG, "onMainDateChanged error: %s", msg)
    end
  end):finally(function()
    inProgress = false
  end)
end

-- ==== Старт/стоп ====
local handler

function M.start()
  logger.info(LOG_TAG, "=== start() ===")
  warmup = true

  -- Страховка: через 3 с warmup снимается принудительно.
  if setTimeout then
    setTimeout(function()
      if warmup then
        warmup = false
        logger.info(LOG_TAG, "warmup снят по таймауту 3с")
      end
    end, 3000)
  end

  -- Инициализация: читаем текущие даты, ставим lastMain*, не запускаем расчёт.
  async(function()
    local res = await(tagApi.readMany({ CH_R.START_MAIN, CH_R.FINISH_MAIN }))
    local s = res and res[1] and toMs(res[1].value)
    local f = res and res[2] and toMs(res[2].value)
    lastMainStart  = s
    lastMainFinish = f
    logger.infoF(LOG_TAG, "init: start=%s, finish=%s", tostring(s), tostring(f))

    await(sleepMs(1000))
    warmup = false
    logger.info(LOG_TAG, "warmup завершён, слушаю изменения")
  end):catch(function(err)
    logger.warnF(LOG_TAG, "init error: %s", tostring(err))
    warmup = false
  end)

  handler = function(event)
    for _, c in ipairs(event.changes or {}) do
      if c.name == CH_R.START_MAIN or c.name == CH_R.FINISH_MAIN then
        logger.infoF(LOG_TAG, "change: name=%s type=%s value=%s%s",
          tostring(c.name), type(c.value), tostring(c.value),
          warmup and " [warmup]" or "")

        if warmup then
          goto continue
        end

        onMainDateChanged()
      end

      ::continue::
    end
  end

  events.on("channelChanges", handler)
  logger.info(LOG_TAG, "subscribed to channelChanges")
end

function M.stop()
  if handler then
    events.off("channelChanges", handler)
    handler = nil
    logger.info(LOG_TAG, "stop(): unsubscribed")
  end
end

return M
