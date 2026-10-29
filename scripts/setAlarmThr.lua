local async = require("async")
local tagApi = require("simplight.api.channels")

local M = {}

local GOOD_QUALITY = 0xC0
local LOG_TAG = "set_alarm_thr"

local CH_R = {
  UST_1 = "Тв_цех.FM-1.Reg_R.SCo_Уставка_Макс",
  UST_2 = "Тв_цех.FM-2.Reg_R.SCo_Уставка_Макс",
  UST_3 = "Тв_цех.FM-3.Reg_R.SCo_Уставка_Макс",
  UST_4 = "Тв_цех.FM-4.Reg_R.SCo_Уставка_Макс",
  UST_5 = "Тв_цех.FM-5.Reg_R.SCo_Уставка_Макс",
  UST_6 = "Тв_цех.FM-6.Reg_R.SCo_Уставка_Макс",
  UST_7 = "Тв_цех.FM-7.Reg_R.SCo_Уставка_Макс",
  UST_22 = "Тв_цех.FM-22.Reg_R.SCo_Уставка_Макс",

  UST_8 = "Тв_цех.FM-8.Reg_R.SCo_Уставка_Макс",
  UST_9 = "Тв_цех.FM-9.Reg_R.SCo_Уставка_Макс",
  UST_10 = "Тв_цех.FM-10.Reg_R.SCo_Уставка_Макс",
  UST_11 = "Тв_цех.FM-11.Reg_R.SCo_Уставка_Макс",
  UST_12 = "Тв_цех.FM-12.Reg_R.SCo_Уставка_Макс",
  UST_13 = "Тв_цех.FM-13.Reg_R.SCo_Уставка_Макс",
  UST_14 = "Тв_цех.FM-14.Reg_R.SCo_Уставка_Макс",
  UST_15 = "Тв_цех.FM-15.Reg_R.SCo_Уставка_Макс",
  UST_16 = "Тв_цех.FM-16.Reg_R.SCo_Уставка_Макс",
  UST_17 = "Тв_цех.FM-17.Reg_R.SCo_Уставка_Макс",
  UST_18 = "Тв_цех.FM-18.Reg_R.SCo_Уставка_Макс",
  UST_19 = "Тв_цех.FM-19.Reg_R.SCo_Уставка_Макс",
  UST_20 = "Тв_цех.FM-20.Reg_R.SCo_Уставка_Макс",
  UST_21 = "Тв_цех.FM-21.Reg_R.SCo_Уставка_Макс",

}

local CH_W = {
  -- Творожный цех
  FLOW_1 = "Тв_цех.FM-1.Reg_R.SCo_Расход",
  FLOW_2 = "Тв_цех.FM-2.Reg_R.SCo_Расход",
  FLOW_3 = "Тв_цех.FM-3.Reg_R.SCo_Расход",
  FLOW_4 = "Тв_цех.FM-4.Reg_R.SCo_Расход",
  FLOW_5 = "Тв_цех.FM-5.Reg_R.SCo_Расход",
  FLOW_6 = "Тв_цех.FM-6.Reg_R.SCo_Расход",
  FLOW_7 = "Тв_цех.FM-7.Reg_R.SCo_Расход",
  FLOW_22 = "Тв_цех.FM-22.Reg_R.SCo_Расход",

  -- Цех СП и нормализации
  FLOW_8 = "Тв_цех.FM-8.Reg_R.SCo_Расход",
  FLOW_9 = "Тв_цех.FM-9.Reg_R.SCo_Расход",
  FLOW_10 = "Тв_цех.FM-10.Reg_R.SCo_Расход",
  FLOW_11 = "Тв_цех.FM-11.Reg_R.SCo_Расход",
  FLOW_12 = "Тв_цех.FM-12.Reg_R.SCo_Расход",
  FLOW_13 = "Тв_цех.FM-13.Reg_R.SCo_Расход",
  FLOW_14 = "Тв_цех.FM-14.Reg_R.SCo_Расход",
  FLOW_15 = "Тв_цех.FM-15.Reg_R.SCo_Расход",
  FLOW_16 = "Тв_цех.FM-16.Reg_R.SCo_Расход",
  FLOW_17 = "Тв_цех.FM-17.Reg_R.SCo_Расход",
  FLOW_18 = "Тв_цех.FM-18.Reg_R.SCo_Расход",
  FLOW_19 = "Тв_цех.FM-19.Reg_R.SCo_Расход",
  FLOW_20 = "Тв_цех.FM-20.Reg_R.SCo_Расход",
  FLOW_21 = "Тв_цех.FM-21.Reg_R.SCo_Расход",
}

local READING_LIST = {
    CH_R.UST_1, CH_R.UST_2, CH_R.UST_3, CH_R.UST_4, CH_R.UST_5, CH_R.UST_6,
    CH_R.UST_7, CH_R.UST_22, CH_R.UST_8, CH_R.UST_9, CH_R.UST_10, CH_R.UST_11,
    CH_R.UST_12, CH_R.UST_13, CH_R.UST_14, CH_R.UST_15, CH_R.UST_16, CH_R.UST_17,
    CH_R.UST_18, CH_R.UST_19, CH_R.UST_20, CH_R.UST_21
}

local WRITING_LIST = {CH_W.FLOW_1, CH_W.FLOW_2, CH_W.FLOW_3, CH_W.FLOW_4,
    CH_W.FLOW_5, CH_W.FLOW_6, CH_W.FLOW_7, CH_W.FLOW_22, CH_W.FLOW_8, CH_W.FLOW_9,
    CH_W.FLOW_10, CH_W.FLOW_11, CH_W.FLOW_12, CH_W.FLOW_13, CH_W.FLOW_14, CH_W.FLOW_15,
    CH_W.FLOW_16, CH_W.FLOW_17, CH_W.FLOW_18, CH_W.FLOW_19, CH_W.FLOW_20, CH_W.FLOW_21
}

local function readValues()
    return async(function()
        local t = await(tagApi.readMany(READING_LIST))

        if not t or #t < #READING_LIST then
            print(string.format("[%s] readMany вернул некорректный результат: %s (ожидалось %d)",
                LOG_TAG, tostring(t and #t or 0), #READING_LIST))
            return nil
        end

        local v = {}
        for i = 1, #READING_LIST do
            if t[i] == nil or t[i].value == nil then
                print(string.format("[%s] Тег %s = nil (индекс %d)",
                    LOG_TAG, READING_LIST[i], i))
                return nil
            end
            v[i] = tonumber(t[i].value) or 0
        end
        return v
    end)
end

local function writeHiHiAlarm(values)
    if #values < #wNames then
        print(string.format("[%s] Количество значений (%d) меньше количества каналов (%d)",
            LOG_TAG, #values, #wNames))
        return
    end

    for i = 1, #wNames do
        local channelName = wNames[i]
        local newMax = values[i]

        --local ok = SetHiHiAlarm(channelName, 0, newMax)
        local ok = setAlarmBounds(channelName, 0, 0, 6, 12)

        if ok then
            print(string.format("[%s] HiHi Alarm установлен: %s -> %s", LOG_TAG, channelName, tostring(newMax)))
        else
            print(string.format("[%s] Ошибка установки HiHi Alarm: %s", LOG_TAG, channelName))
        end
    end


function M.start()
    return async(function()
        local v = await(readValues())
        if not v then return end

        writeHiHiAlarm(v)
    )
end

return M