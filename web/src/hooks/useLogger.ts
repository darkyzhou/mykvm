import { useCallback, useState } from 'react';

export type LogType = 'info' | 'error' | 'success';

export interface LogEntry {
  id: number;
  message: string;
  type: LogType;
}

let logId = 0;

export function useLogger() {
  const [logs, setLogs] = useState<LogEntry[]>([
    { id: logId++, message: 'MYKVM BIOS v1.0', type: 'info' },
    { id: logId++, message: 'Initializing system...', type: 'info' },
    { id: logId++, message: 'Waiting for command...', type: 'info' },
  ]);

  const log = useCallback((message: string, type: LogType = 'info') => {
    setLogs((prev) => [
      ...prev,
      { id: logId++, message, type },
    ]);
  }, []);

  const clearLogs = useCallback(() => {
    setLogs([]);
  }, []);

  return { logs, log, clearLogs };
}

