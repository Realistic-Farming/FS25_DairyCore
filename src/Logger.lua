-- =========================================================
-- FS25_DairyCore - Logger
-- =========================================================
-- Author: TisonK
-- Mirrors the Realistic Farming logging pattern; greppable by "[DairyCore]".
-- =========================================================

DCLogger = {}
DCLogger.PREFIX = "[DairyCore] "
DCLogger.debugEnabled = false

function DCLogger.info(msg, ...)
    if select("#", ...) > 0 then Logging.info(DCLogger.PREFIX .. msg, ...)
    else Logging.info(DCLogger.PREFIX .. msg) end
end

function DCLogger.warning(msg, ...)
    if select("#", ...) > 0 then Logging.warning(DCLogger.PREFIX .. msg, ...)
    else Logging.warning(DCLogger.PREFIX .. msg) end
end

function DCLogger.error(msg, ...)
    if select("#", ...) > 0 then Logging.error(DCLogger.PREFIX .. msg, ...)
    else Logging.error(DCLogger.PREFIX .. msg) end
end

function DCLogger.debug(msg, ...)
    if not DCLogger.debugEnabled then return end
    if select("#", ...) > 0 then Logging.info(DCLogger.PREFIX .. "[debug] " .. msg, ...)
    else Logging.info(DCLogger.PREFIX .. "[debug] " .. msg) end
end
