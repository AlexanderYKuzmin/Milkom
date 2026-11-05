-- countDataPeriod.lua
-- Расчёт среднего, максимального и минимального архивных значений расхода
-- по одному расходомеру за период, плюс потребление по показаниям счётчика.
local async = require("async")
local tagApi = require("simplight.api.channels")
local momentApi = require("moments")

local M = {}

local GOOD_QUALITY = 0xC0

-- params = {
--   source         = "Тв_цех.FM-1.Reg_R.SCo_Расход",   -- тег расхода (обязателен)
--   volumeSource   = "Тв_цех.FM-1.Reg_R.SCo_Объем",    -- тег показаний счётчика (опц.)
--   avgTag         = "1_Ср_расх_период",               -- куда писать среднее (опц.)
--   maxTag         = "1_Макс_расх_период",             -- куда писать максимум (опц.)
--   minTag         = "1_Мин_расх_период",              -- куда писать минимум (опц.)
--   consumptionTag = "1_Потребление_период",           -- куда писать потребление (опц.)
--   period         = { start = <ms>, finish = <ms> },  -- обязателен
--   onDone         = function(ok, result) end,         -- необязательный колбэк
-- }
function M.countDataPeriod(params)
  if type(params) ~= "table" then
    print("[countDataPeriod] params is not a table")
    return
  end

  local source = params.source
  local period = params.period or {}
  local tStart = tonumber(period.start)
  local tEnd = tonumber(period.finish)

  if type(source) ~= "string" or source == "" then
    print("[countDataPeriod] source tag is not specified")
    return
  end

  if tStart == nil or tEnd == nil then
    print("[countDataPeriod] invalid period:", tostring(period.start), tostring(period.finish))
    return
  end

  if tEnd <= tStart then
    print("[countDataPeriod] finish <= start, skip:", tStart, tEnd)
    return
  end

  async(function()
    local optsFlow = {
      channelName = source,
      start = tStart,
      ending = tEnd,
    }

    local avg = await(momentApi.getAverage(optsFlow))
    local max = await(momentApi.getMax(optsFlow))
    local min = await(momentApi.getMin(optsFlow))

    local result = { avg = avg, max = max, min = min }

    if avg == nil then
      print("[countDataPeriod] no archive data for average:", source)
    end
    if max == nil then
      print("[countDataPeriod] no archive data for max:", source)
    end
    if min == nil then
      print("[countDataPeriod] no archive data for min:", source)
    end

    -- Потребление по показаниям счётчика (если задан volumeSource)
    local consumption
    if params.volumeSource and params.consumptionTag then
      local optsVol = { channelName = params.volumeSource, start = tStart, ending = tEnd }
      local vMin = await(momentApi.getMin(optsVol))
      local vMax = await(momentApi.getMax(optsVol))

      if vMin == nil or vMax == nil then
        print("[countDataPeriod] no archive data for volume:", params.volumeSource)
      else
        consumption = vMax - vMin
        if consumption < 0 then
          print("[countDataPeriod] negative consumption, possible meter reset:", params.volumeSource)
          consumption = 0
        end
      end
      result.consumption = consumption
    end

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

    if #values > 0 then
      await(tagApi.writeMany({ values = values }))
    end

    print(string.format(
      "[countDataPeriod] %s [%d..%d]: avg=%s max=%s min=%s cons=%s",
      source, tStart, tEnd,
      tostring(avg), tostring(max), tostring(min), tostring(consumption)
    ))

    if type(params.onDone) == "function" then
      params.onDone(true, result)
    end
  end)
  :catch(function(err)
    print("[countDataPeriod] error:", err)
    if type(params.onDone) == "function" then
      params.onDone(false, err)
    end
  end)
end

return M