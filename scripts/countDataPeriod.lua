-- countDataPeriod.lua
-- Расчёт среднего, максимального и минимального архивных значений расхода
-- по одному расходомеру за период, плюс потребление по показаниям счётчика.
local async      = require("async")
local tagApi     = require("simplight.api.channels")
local momentApi  = require("moments")
local logger     = require("logger")

local M = {}

local LOG_TAG = "countDataPeriod"
local GOOD_QUALITY = 0xC0

local function toNum(v)
  if v == nil then return nil end
  local n = tonumber(v)
  if n ~= nil then return n end
  return nil
end

-- params = {
--   source         = "Тв_цех.FM-1.Reg_R.SCo_Расход",
--   volumeSource   = "Тв_цех.FM-1.Reg_R.SCo_Объем",
--   avgTag         = "1_Ср_расх_период",
--   maxTag         = "1_Макс_расх_период",
--   minTag         = "1_Мин_расх_период",
--   consumptionTag = "1_Потребление_период",
--   period         = { start = <ms>, finish = <ms> },
--   onDone         = function(ok, result) end,  -- опционально
-- }
function M.countDataPeriod(params)
  if type(params) ~= "table" then
    logger.warn(LOG_TAG, "params is not a table")
    return
  end

  local source = params.source
  local period = params.period or {}
  local tStart = tonumber(period.start)
  local tEnd   = tonumber(period.finish)

  if type(source) ~= "string" or source == "" then
    logger.warn(LOG_TAG, "source tag is not specified")
    return
  end

  if tStart == nil or tEnd == nil then
    logger.warnF(LOG_TAG, "invalid period: start=%s, finish=%s",
      tostring(period.start), tostring(period.finish))
    return
  end

  if tEnd <= tStart then
    logger.warnF(LOG_TAG, "finish <= start, skip: %d..%d", tStart, tEnd)
    return
  end

  logger.infoF(LOG_TAG, "start: source=%s, period=%d..%d",
    source, tStart, tEnd)

  async(function()
    local optsFlow = {
      channelName = source,
      start = tStart,
      ending = tEnd,
    }

    -- ---- avg ----
    local avg
    do
      logger.infoF(LOG_TAG, "reading average for %s", source)
      local ok, err = pcall(function()
        avg = await(momentApi.getAverage(optsFlow))
      end)
      if not ok then
        logger.warnF(LOG_TAG, "getAverage failed for %s: %s", source, tostring(err))
        avg = nil
      end
      logger.infoF(LOG_TAG, "getAverage -> %s", tostring(avg))
    end

    -- ---- max ----
    local max
    do
      logger.infoF(LOG_TAG, "reading max for %s", source)
      local ok, err = pcall(function()
        max = await(momentApi.getMax(optsFlow))
      end)
      if not ok then
        logger.warnF(LOG_TAG, "getMax failed for %s: %s", source, tostring(err))
        max = nil
      end
      logger.infoF(LOG_TAG, "getMax -> %s", tostring(max))
    end

    -- ---- min ----
    local min
    do
      logger.infoF(LOG_TAG, "reading min for %s", source)
      local ok, err = pcall(function()
        min = await(momentApi.getMin(optsFlow))
      end)
      if not ok then
        logger.warnF(LOG_TAG, "getMin failed for %s: %s", source, tostring(err))
        min = nil
      end
      logger.infoF(LOG_TAG, "getMin -> %s", tostring(min))
    end

    local result = { avg = avg, max = max, min = min }

    if avg == nil then
      logger.warnF(LOG_TAG, "no archive data for average: %s", source)
    end
    if max == nil then
      logger.warnF(LOG_TAG, "no archive data for max: %s", source)
    end
    if min == nil then
      logger.warnF(LOG_TAG, "no archive data for min: %s", source)
    end

    -- ---- consumption ----
    local consumption
    if params.volumeSource and params.consumptionTag then
      local optsVol = { channelName = params.volumeSource, start = tStart, ending = tEnd }

      logger.infoF(LOG_TAG, "reading min/max volume for %s", params.volumeSource)

      local vMin, vMax
      do
        local ok, err = pcall(function()
          vMin = await(momentApi.getMin(optsVol))
        end)
        if not ok then
          logger.warnF(LOG_TAG, "getMin(volume) failed for %s: %s",
            params.volumeSource, tostring(err))
          vMin = nil
        end
        logger.infoF(LOG_TAG, "getMin(volume) -> %s", tostring(vMin))
      end

      do
        local ok, err = pcall(function()
          vMax = await(momentApi.getMax(optsVol))
        end)
        if not ok then
          logger.warnF(LOG_TAG, "getMax(volume) failed for %s: %s",
            params.volumeSource, tostring(err))
          vMax = nil
        end
        logger.infoF(LOG_TAG, "getMax(volume) -> %s", tostring(vMax))
      end

      if vMin == nil or vMax == nil then
        logger.warnF(LOG_TAG, "no archive data for volume: %s", params.volumeSource)
      else
        consumption = toNum(vMax) - toNum(vMin)
        if consumption == nil then
          logger.warnF(LOG_TAG, "cannot convert volume to number: min=%s max=%s",
            tostring(vMin), tostring(vMax))
          consumption = nil
        elseif consumption < 0 then
          logger.warnF(LOG_TAG, "negative consumption (%s), possible meter reset: %s",
            tostring(consumption), params.volumeSource)
          consumption = 0
        end
      end
      result.consumption = consumption
    end

    -- ---- build values ----
    local values = {}
    if params.avgTag and avg ~= nil then
      values[#values + 1] = { name = params.avgTag, value = avg, quality = GOOD_QUALITY }
    end
    if params.maxTag and max ~= nil then
      values[#values + 1] = { name = params.maxTag, value = max, quality = GOOD_QUALITY }
    end
    if params.minTag and min ~= nil then
      values[#values + 1] = { name = params.minTag, value = min, quality = GOOD_QUALITY }
    end
    if params.consumptionTag and consumption ~= nil then
      values[#values + 1] = { name = params.consumptionTag, value = consumption, quality = GOOD_QUALITY }
    end

    logger.infoF(LOG_TAG, "writeMany: %d tag(s), avg=%s max=%s min=%s cons=%s",
      #values, tostring(avg), tostring(max), tostring(min), tostring(consumption))

    if #values > 0 then
      local ok, err = pcall(function()
        await(tagApi.writeMany({ values = values }))
      end)
      if not ok then
        logger.warnF(LOG_TAG, "writeMany failed: %s", tostring(err))
      else
        logger.infoF(LOG_TAG, "writeMany OK: %d tag(s)", #values)
      end
    else
      logger.warnF(LOG_TAG, "nothing to write (all results nil)")
    end

    logger.infoF(LOG_TAG, "done: %s [%d..%d]: avg=%s max=%s min=%s cons=%s",
      source, tStart, tEnd,
      tostring(avg), tostring(max), tostring(min), tostring(consumption))

    if type(params.onDone) == "function" then
      params.onDone(true, result)
    end
  end)
  :catch(function(err)
    local msg = tostring(err)
    if msg:find("context canceled", 1, true) then
      logger.warnF(LOG_TAG, "%s: отменено перезагрузкой", source)
    else
      logger.warnF(LOG_TAG, "async error: %s", msg)
    end
    if type(params.onDone) == "function" then
      params.onDone(false, err)
    end
  end)
end

return M
