-- log.lua
-- Общий модуль логирования для скриптов Simplight.
-- Пишет сообщения в общий Журнал событий через funcs.logEvents.
--
-- Использование:
--   local log = require("log")
--   log.info("lenin_flow_water", "расход в норме")
--   log.infoF("lenin_flow_water", "мгнов=%.3f, сутки=%.3f", flow, day)
--   log.warnF("scheduler", "шаг SLOW %d/%d %s dt=%d мс", i, n, label, dt)
--   log.alarmF("scheduler", "шаг ALARM %d/%d %s: %s", i, n, label, err)
--
-- Уровни:
--   info  — обычные информационные сообщения
--   warn  — предупреждения (warning; при отсутствии в SDK падает в info)
--   alarm — аварийные сообщения (используется вместо error)

local funcs = require("funcs")

local M = {}

-- Кэшируем типы событий при загрузке модуля.
local T_INFO  = funcs.eventType.info
local T_WARN  = (funcs.eventType and funcs.eventType.warning) or T_INFO
local T_ALARM = (funcs.eventType and funcs.eventType.alarm)   or T_INFO

--- Низкоуровневая отправка. Защищена pcall: если logEvents недоступен,
--- сообщение всё равно уйдёт в stdout, чтобы не потерялось.
--- @param eventType number|string
--- @param tag string
--- @param text string
local function emit(eventType, tag, text)
  local ok, err = pcall(function()
    funcs.logEvents({
      type = eventType,
      text = string.format("[%s] %s", tag, text),
    })
  end)
  if not ok then
    print(string.format("[log] logEvents failed: %s; fallback: [%s] %s",
      tostring(err), tostring(tag), tostring(text)))
  end
end

-- === info ===

function M.info(tag, text)
  emit(T_INFO, tag, text)
end

function M.infoF(tag, fmt, ...)
  emit(T_INFO, tag, string.format(fmt, ...))
end

-- === warn ===

function M.warn(tag, text)
  emit(T_WARN, tag, text)
end

function M.warnF(tag, fmt, ...)
  emit(T_WARN, tag, string.format(fmt, ...))
end

-- === alarm ===

function M.alarm(tag, text)
  emit(T_ALARM, tag, text)
end

function M.alarmF(tag, fmt, ...)
  emit(T_ALARM, tag, string.format(fmt, ...))
end

-- === диагностика (опционально) ===
-- Возвращает таблицу с фактическими типами событий,
-- чтобы можно было проверить, что SDK отдал.
function M.levels()
  return {
    info  = T_INFO,
    warn  = T_WARN,
    alarm = T_ALARM,
  }
end

return M