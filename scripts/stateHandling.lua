local async = require("async")
local tagApi = require("simplight.api.channels")
local events = require("simp-events")
local bitop = require("bitop")
local log = require("log")

local M = {}

local LOG_TAG = ""

-- Соответствие тегов и читаемых имён.
-- Порядок соответствует порядку опроса в READING_LIST.
local STATE_TAGS = {
  { tag = "Тв_цех.FM-1.Reg_R.Sco_Состояние",  name = "Расходомер-1"  },
  { tag = "Тв_цех.FM-2.Reg_R.Sco_Состояние",  name = "Расходомер-2"  },
  { tag = "Тв_цех.FM-3.Reg_R.Sco_Состояние",  name = "Расходомер-3"  },
  { tag = "Тв_цех.FM-4.Reg_R.Sco_Состояние",  name = "Расходомер-4"  },
  { tag = "Тв_цех.FM-5.Reg_R.Sco_Состояние",  name = "Расходомер-5"  },
  { tag = "Тв_цех.FM-6.Reg_R.Sco_Состояние",  name = "Расходомер-6"  },
  { tag = "Тв_цех.FM-7.Reg_R.Sco_Состояние",  name = "Расходомер-7"  },
  { tag = "Тв_цех.FM-22.Reg_R.Sco_Состояние", name = "Расходомер-22" },
  { tag = "Тв_цех.FM-8.Reg_R.Sco_Состояние",  name = "Расходомер-8"  },
  { tag = "Тв_цех.FM-9.Reg_R.Sco_Состояние",  name = "Расходомер-9"  },
  { tag = "Тв_цех.FM-10.Reg_R.Sco_Состояние", name = "Расходомер-10" },
  { tag = "Тв_цех.FM-11.Reg_R.Sco_Состояние", name = "Расходомер-11" },
  { tag = "Тв_цех.FM-12.Reg_R.Sco_Состояние", name = "Расходомер-12" },
  { tag = "Тв_цех.FM-13.Reg_R.Sco_Состояние", name = "Расходомер-13" },
  { tag = "Тв_цех.FM-14.Reg_R.Sco_Состояние", name = "Расходомер-14" },
  { tag = "Тв_цех.FM-15.Reg_R.Sco_Состояние", name = "Расходомер-15" },
  { tag = "Тв_цех.FM-16.Reg_R.Sco_Состояние", name = "Расходомер-16" },
  { tag = "Тв_цех.FM-17.Reg_R.Sco_Состояние", name = "Расходомер-17" },
  { tag = "Тв_цех.FM-18.Reg_R.Sco_Состояние", name = "Расходомер-18" },
  { tag = "Тв_цех.FM-19.Reg_R.Sco_Состояние", name = "Расходомер-19" },
  { tag = "Тв_цех.FM-20.Reg_R.Sco_Состояние", name = "Расходомер-20" },
  { tag = "Тв_цех.FM-21.Reg_R.Sco_Состояние", name = "Расходомер-21" },
}

-- Быстрый поиск по имени тега + список имён для readMany
local tagInfo = {}
local tagNames = {}
for _, item in ipairs(STATE_TAGS) do
  tagInfo[item.tag] = item
  tagNames[#tagNames + 1] = item.tag
end

-- Предыдущее состояние бита тревоги по каждому тегу.
-- nil — ещё не было начального чтения.
local lastAlarmBit = {}

-- === Вспомогательные функции (стиль из ust_states.lua) ===

--- Проверка бита в маске через bitop.band
local function hasBit(mask, w)
  mask = tonumber(mask) or 0
  w = tonumber(w) or 0
  return bitop.band(mask, w) ~= 0
end

--- Проверка логического значения: true или 1
local function isTrue(v)
  return v == true or tonumber(v) == 1
end

--- Бит 1 (второй бит, вес 2) — тревога
local function isAlarmBitSet(value)
  local v = tonumber(value) or 0
  return hasBit(v, 2)
end

-- === Обработка изменения одного тега ===

local function handleChange(tagName, newValue)
  local info = tagInfo[tagName]
  if not info then
    return
  end

  local nowAlarm = isAlarmBitSet(newValue)

  -- При начальном чтении lastAlarmBit[tagName] == nil —
  -- начальная логика обрабатывается в initialCheck, здесь пропускаем.
  if lastAlarmBit[tagName] == nil then
    lastAlarmBit[tagName] = nowAlarm
    return
  end

  -- Логируем только при фактической смене состояния бита
  if lastAlarmBit[tagName] == nowAlarm then
    return
  end
  lastAlarmBit[tagName] = nowAlarm

  if nowAlarm then
    log.alarmF(LOG_TAG, "[%s] Расход выше порогового значения", info.name)
  else
    log.infoF(LOG_TAG, "[%s] Расход в норме", info.name)
  end
end

-- === Начальное чтение ===

--- При запуске читаем все теги состояния и логируем alarm только для тех,
--- где бит 1 == 1. Для нулевых значений info не пишем, чтобы не засорять
--- журнал при старте. lastAlarmBit заполняется для последующей обработки изменений.
local function initialCheck()
  return async(function()
    local results = await(tagApi.readMany(tagNames))
    if not results or #results < #tagNames then
      log.warnF(LOG_TAG, "initialCheck: readMany вернул некорректный результат (%s из %d)",
        tostring(results and #results or 0), #tagNames)
      return
    end

    for i, tag in ipairs(tagNames) do
      local entry = results[i]
      local value = entry and entry.value
      local nowAlarm = isAlarmBitSet(value)
      lastAlarmBit[tag] = nowAlarm

      if nowAlarm then
        log.alarmF(LOG_TAG, "[%s] Расход выше порогового значения", tagInfo[tag].name)
      end
    end
  end)
end

-- === Старт модуля ===

function M.start()
  -- 1) Начальное чтение (асинхронно), затем подписка на изменения
  initialCheck()
    :catch(function(err)
      log.alarmF(LOG_TAG, "initialCheck error: %s", tostring(err))
    end)

  -- 2) Подписка на изменения каналов
  events.on("channelChanges", function(event)
    for _, change in ipairs(event.changes or {}) do
      handleChange(change.name, change.value)
    end
  end)
end

return M
