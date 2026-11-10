-- logger.lua
-- Пишет в C:\Users\Public\Documents\SimpLight_5.0\app.log
-- и дублирует в print (журнал сообщений Simplight).

local M = {}

local LOG_PATH = "C:\\Users\\Public\\Documents\\SimpLight_5.0\\app.log"

local function writeLine(level, tag, text)
  local line = string.format("%s [%s] [%s] %s\n",
    os.date("%Y-%m-%d %H:%M:%S"),
    level,
    tostring(tag or ""),
    tostring(text))

  -- 1) в файл
  local fh, err = io.open(LOG_PATH, "a")
  if fh then
    local ok = pcall(function()
      fh:write(line)
      fh:flush()
    end)
    fh:close()
    if not ok then
      print(string.format("[logger] file write failed for %s: %s", LOG_PATH, line))
    end
  else
    print(string.format("[logger] open failed (%s): %s; fallback: %s",
      tostring(err), LOG_PATH, line))
  end

  -- 2) дублируем в print (в журнал сообщений Simplight)
  print(line)
end

function M.setFile(path)
  if type(path) == "string" and path ~= "" then
    LOG_PATH = path
    writeLine("INFO", "logger", "setFile: " .. path)
  end
end

function M.getFile()
  return LOG_PATH
end

function M.info(tag, text)
  writeLine("INFO", tag, text)
end

function M.infoF(tag, fmt, ...)
  writeLine("INFO", tag, string.format(fmt, ...))
end

function M.warn(tag, text)
  writeLine("WARN", tag, text)
end

function M.warnF(tag, fmt, ...)
  writeLine("WARN", tag, string.format(fmt, ...))
end

function M.error(tag, text)
  writeLine("ERROR", tag, text)
end

function M.errorF(tag, fmt, ...)
  writeLine("ERROR", tag, string.format(fmt, ...))
end

return M
