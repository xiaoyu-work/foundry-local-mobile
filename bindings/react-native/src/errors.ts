// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

/**
 * The `flm_status` codes, mirrored 1:1 as string tags so unfamiliar callers
 * do not read a bare integer with no way to look it up.
 */
export type FoundryLocalErrorCode =
  | 'ok'
  | 'internal'
  | 'invalidArgument'
  | 'invalidHandle'
  | 'invalidState'
  | 'notFound'
  | 'notImplemented'
  | 'cancelled'
  | 'network'
  | 'storage'
  | 'outOfMemory'
  | 'incompatible'
  | 'timeout'
  | 'unsupportedVersion'
  | 'memoryPressure'
  | 'shutdown'
  | 'unknown';

const CODE_BY_STATUS: Record<number, FoundryLocalErrorCode> = {
  0: 'ok',
  1: 'internal',
  2: 'invalidArgument',
  3: 'invalidHandle',
  4: 'invalidState',
  5: 'notFound',
  6: 'notImplemented',
  7: 'cancelled',
  8: 'network',
  9: 'storage',
  10: 'outOfMemory',
  11: 'incompatible',
  12: 'timeout',
  13: 'unsupportedVersion',
  14: 'memoryPressure',
  15: 'shutdown',
};

export function statusToCode(status: number): FoundryLocalErrorCode {
  return CODE_BY_STATUS[status] ?? 'unknown';
}

/**
 * Base error raised by every SDK operation.
 *
 * The native side surfaces failures as a JSON payload (status + message +
 * detail); this class decodes it into a typed object. `detailJson` is the raw
 * string a caller can inspect if it needs unmodelled fields.
 */
export class FoundryLocalError extends Error {
  public readonly code: FoundryLocalErrorCode;
  public readonly status: number;
  public readonly detailJson: string | null;
  public readonly isRetryable: boolean;

  constructor(
    status: number,
    message: string,
    detailJson: string | null,
    code?: FoundryLocalErrorCode,
  ) {
    super(message);
    this.name = 'FoundryLocalError';
    this.status = status;
    this.detailJson = detailJson;
    this.code = code ?? statusToCode(status);
    this.isRetryable = parseRetryable(detailJson);
    Object.setPrototypeOf(this, new.target.prototype);
  }

  /**
   * `{ retryable, context: {...} }` parsed from `detailJson`, or `null` if
   * the detail was not JSON. The core populates `context` with structured
   * fields — HTTP status, URL, missing model id — depending on the error.
   */
  public get detail(): { retryable?: boolean; context?: Record<string, unknown> } | null {
    if (!this.detailJson) return null;
    try {
      return JSON.parse(this.detailJson);
    } catch {
      return null;
    }
  }

  /**
   * Rebuild an error from what the native module produced. Recognises a JSON
   * payload of the shape `{ status, message, detail }` and falls back to a
   * plain-message wrap for legacy callers.
   */
  static fromNative(raw: unknown): FoundryLocalError {
    if (raw instanceof FoundryLocalError) return raw;
    if (raw instanceof Error) {
      const anyRaw = raw as Error & {
        userInfo?: { status?: number; detail?: string; code?: string };
        code?: string;
      };
      const info = anyRaw.userInfo ?? {};
      const status = typeof info.status === 'number' ? info.status : -1;
      const detailJson = typeof info.detail === 'string' ? info.detail : null;
      return new FoundryLocalError(status, raw.message, detailJson);
    }
    if (typeof raw === 'string') {
      return new FoundryLocalError(-1, raw, null, 'unknown');
    }
    return new FoundryLocalError(-1, 'Unknown native error', null, 'unknown');
  }
}

function parseRetryable(detailJson: string | null): boolean {
  if (!detailJson) return false;
  try {
    const obj = JSON.parse(detailJson) as { retryable?: unknown };
    return obj.retryable === true || obj.retryable === 'true';
  } catch {
    return false;
  }
}
